-- ============================================================================
-- Rubbleit security hardening migration
-- Run this in the SQL editor of the LIVE Supabase project (bfekeamjuiytiiexbflt).
--
-- What it fixes (both are launch blockers):
--   1. Credit fraud: credits were updated directly from the browser, so any
--      logged-in business could grant themselves unlimited credits.
--   2. Contact leak: the dashboard fetched every job's customer name / phone /
--      email into the browser; the "locked" blur was only cosmetic, so paid
--      contact details were readable for free.
--
-- Approach: stop trusting the client. Row Level Security scopes every table to
-- its owner, credit changes are blocked except through a trusted server-side
-- function, and customer contact columns are only readable via a function that
-- verifies the caller actually paid to unlock that lead.
--
-- This script is idempotent: safe to run more than once.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Row Level Security
-- ---------------------------------------------------------------------------

alter table public.businesses          enable row level security;
alter table public.listings            enable row level security;
alter table public.jobs                enable row level security;
alter table public.lead_unlocks        enable row level security;
alter table public.credit_transactions enable row level security;

-- businesses: a business can only see and edit its own row.
drop policy if exists businesses_select_own on public.businesses;
create policy businesses_select_own on public.businesses
  for select to authenticated using (id = auth.uid());

drop policy if exists businesses_insert_own on public.businesses;
create policy businesses_insert_own on public.businesses
  for insert to authenticated with check (id = auth.uid());

drop policy if exists businesses_update_own on public.businesses;
create policy businesses_update_own on public.businesses
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- listings: a business can only see and edit its own listing.
-- (The public site reads published listings through the listing_cards VIEW,
--  which runs as its owner and bypasses these row policies — see section 5.)
drop policy if exists listings_select_own on public.listings;
create policy listings_select_own on public.listings
  for select to authenticated using (business_id = auth.uid());

drop policy if exists listings_insert_own on public.listings;
create policy listings_insert_own on public.listings
  for insert to authenticated with check (business_id = auth.uid());

drop policy if exists listings_update_own on public.listings;
create policy listings_update_own on public.listings
  for update to authenticated using (business_id = auth.uid()) with check (business_id = auth.uid());

-- jobs: anyone (a customer on the public site) can post a job. Businesses can
-- read the job feed, but contact columns are stripped in section 3.
drop policy if exists jobs_insert_public on public.jobs;
create policy jobs_insert_public on public.jobs
  for insert to anon, authenticated with check (true);

drop policy if exists jobs_select_authenticated on public.jobs;
create policy jobs_select_authenticated on public.jobs
  for select to authenticated using (true);

-- lead_unlocks: a business only sees its own unlocks.
drop policy if exists lead_unlocks_select_own on public.lead_unlocks;
create policy lead_unlocks_select_own on public.lead_unlocks
  for select to authenticated using (business_id = auth.uid());

-- credit_transactions: a business only sees its own history and may log its own
-- (non-credit-bearing) rows such as the free-trial grant.
drop policy if exists credit_tx_select_own on public.credit_transactions;
create policy credit_tx_select_own on public.credit_transactions
  for select to authenticated using (business_id = auth.uid());

drop policy if exists credit_tx_insert_own on public.credit_transactions;
create policy credit_tx_insert_own on public.credit_transactions
  for insert to authenticated with check (business_id = auth.uid());

-- ---------------------------------------------------------------------------
-- 2. Credit tamper protection
--    Force new businesses to start at 3 credits and block any client-driven
--    change to the credits column. Only unlock_lead() (section 4) may change
--    it, which it authorises with a transaction-local flag.
-- ---------------------------------------------------------------------------

alter table public.businesses alter column credits set default 3;

create or replace function public.protect_credits()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' then
    -- Ignore whatever the client sent; every new business starts with 3.
    new.credits := 3;
    return new;
  end if;

  -- UPDATE: silently keep the old balance unless a trusted server function
  -- has set the authorisation flag for this transaction. This lets normal
  -- profile updates (name, phone, postcode) through untouched.
  if new.credits is distinct from old.credits
     and coalesce(current_setting('app.allow_credit_change', true), '0') <> '1' then
    new.credits := old.credits;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_protect_credits on public.businesses;
create trigger trg_protect_credits
  before insert or update on public.businesses
  for each row execute function public.protect_credits();

-- ---------------------------------------------------------------------------
-- 3. Hide customer contact columns from direct client reads
--    Businesses can read the job feed, but never the raw contact fields.
--    Contact details are only handed out by unlock_lead() / my_unlocked_leads().
-- ---------------------------------------------------------------------------

grant  select on public.jobs to authenticated;
revoke select (customer_name, customer_phone, customer_email) on public.jobs from authenticated;
revoke select on public.jobs from anon;             -- the public site only inserts jobs
grant  insert on public.jobs to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Trusted server-side functions
-- ---------------------------------------------------------------------------

-- Atomically unlock a lead: verifies the caller, computes the price server-side
-- (so the client cannot claim a cheaper cost), checks the balance, deducts
-- credits, records the unlock + transaction, and returns the contact details.
create or replace function public.unlock_lead(p_job_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business uuid := auth.uid();
  v_cost     int;
  v_waste    text;
  v_credits  int;
  v_name     text;
  v_phone    text;
  v_email    text;
  v_already  boolean := false;
begin
  if v_business is null then
    raise exception 'Not authenticated';
  end if;

  select waste_type, customer_name, customer_phone, customer_email
    into v_waste, v_name, v_phone, v_email
    from public.jobs where id = p_job_id;
  if not found then
    raise exception 'Job not found';
  end if;

  -- Already paid for? Return the contact again without charging.
  perform 1 from public.lead_unlocks
    where business_id = v_business and job_id = p_job_id;
  if found then
    v_already := true;
  end if;

  if v_already then
    return json_build_object(
      'already_unlocked', true,
      'customer_name', v_name,
      'customer_phone', v_phone,
      'customer_email', v_email,
      'credits_remaining', (select credits from public.businesses where id = v_business)
    );
  end if;

  -- Premium job types cost 2 credits, everything else 1. Authoritative here.
  v_cost := case when v_waste in ('Commercial clearance', 'Hazardous waste') then 2 else 1 end;

  select credits into v_credits
    from public.businesses where id = v_business for update;
  if v_credits is null then
    raise exception 'Business not found';
  end if;

  if v_credits < v_cost then
    return json_build_object('error', 'insufficient_credits', 'credits_remaining', v_credits);
  end if;

  -- Authorise the credit change for this transaction only, then deduct.
  perform set_config('app.allow_credit_change', '1', true);
  update public.businesses set credits = credits - v_cost where id = v_business;

  insert into public.lead_unlocks (business_id, job_id, credits_spent)
    values (v_business, p_job_id, v_cost);
  insert into public.credit_transactions (business_id, amount, type)
    values (v_business, -v_cost, 'spend');

  return json_build_object(
    'success', true,
    'customer_name', v_name,
    'customer_phone', v_phone,
    'customer_email', v_email,
    'credits_remaining', v_credits - v_cost
  );
end;
$$;

-- Return contact details for every lead the caller has already unlocked, so the
-- dashboard can re-render them after a page reload without exposing anything
-- the business has not paid for.
create or replace function public.my_unlocked_leads()
returns table (job_id uuid, customer_name text, customer_phone text, customer_email text)
language sql
security definer
set search_path = public
stable
as $$
  select j.id, j.customer_name, j.customer_phone, j.customer_email
  from public.lead_unlocks lu
  join public.jobs j on j.id = lu.job_id
  where lu.business_id = auth.uid();
$$;

revoke all on function public.unlock_lead(uuid)      from public, anon;
revoke all on function public.my_unlocked_leads()    from public, anon;
grant  execute on function public.unlock_lead(uuid)   to authenticated;
grant  execute on function public.my_unlocked_leads() to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Keep the public search working under RLS
--    listing_cards must run as its owner (NOT security_invoker) so anonymous
--    visitors can still read published listings even though RLS now guards the
--    underlying tables.
-- ---------------------------------------------------------------------------

do $$
begin
  execute 'alter view public.listing_cards set (security_invoker = false)';
exception when others then
  -- Older Postgres without the security_invoker option: views already run as
  -- owner by default, so nothing to do.
  null;
end;
$$;

grant select on public.listing_cards to anon, authenticated;

-- ============================================================================
-- After running this, deploy the matching client changes in rubble-dashboard.html
-- (loadLeads + unlockLead now go through the functions above).
-- ============================================================================
