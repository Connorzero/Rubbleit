-- Step 1: quote marketplace foundations (membership + success fee model).
-- Additive only: the legacy credit system (lead_unlocks, credit_transactions,
-- unlock_lead, my_unlocked_leads) keeps working until the switchover step.

-- ---------------------------------------------------------------------------
-- Platform settings (single row)
-- ---------------------------------------------------------------------------
create table if not exists public.platform_settings (
  id boolean primary key default true check (id),
  membership_price_id text,
  membership_price_pence int not null default 2900,
  fee_percent numeric(5,2) not null default 12 check (fee_percent between 0 and 100),
  fee_min_pence int not null default 500 check (fee_min_pence >= 0),
  fee_max_pence int not null default 6000 check (fee_max_pence >= fee_min_pence),
  max_quotes_per_job int not null default 3 check (max_quotes_per_job between 1 and 10),
  claim_hold_minutes int not null default 120 check (claim_hold_minutes between 5 and 1440),
  trial_days int not null default 30 check (trial_days between 0 and 90),
  updated_at timestamptz not null default now()
);
insert into public.platform_settings (id) values (true) on conflict (id) do nothing;

alter table public.platform_settings enable row level security;
revoke all on public.platform_settings from anon, authenticated;
grant select on public.platform_settings to anon, authenticated;
drop policy if exists platform_settings_public_read on public.platform_settings;
create policy platform_settings_public_read on public.platform_settings
  for select to anon, authenticated using (true);

-- ---------------------------------------------------------------------------
-- Businesses: membership, billing and coverage radius
-- ---------------------------------------------------------------------------
alter table public.businesses
  add column if not exists stripe_subscription_id text,
  add column if not exists trial_ends_at timestamptz,
  add column if not exists default_payment_method_id text,
  add column if not exists has_unpaid_fee boolean not null default false,
  add column if not exists is_admin boolean not null default false,
  add column if not exists base_postcode text,
  add column if not exists base_lat double precision,
  add column if not exists base_lng double precision,
  add column if not exists coverage_radius_miles int not null default 15;

alter table public.businesses drop constraint if exists businesses_coverage_radius_check;
alter table public.businesses add constraint businesses_coverage_radius_check
  check (coverage_radius_miles in (5, 10, 15, 25, 40));
alter table public.businesses drop constraint if exists businesses_base_coords_check;
alter table public.businesses add constraint businesses_base_coords_check
  check (
    (base_lat is null and base_lng is null)
    or (base_lat between 49.8 and 60.95 and base_lng between -8.7 and 1.8)
  );

-- Billing/admin columns are only ever written by the server (service role).
-- Existing column-level UPDATE grants for authenticated are left unchanged,
-- so these new columns are not user-editable. Coverage goes through set_coverage().

-- ---------------------------------------------------------------------------
-- Jobs: quote lifecycle, location and customer access token
-- ---------------------------------------------------------------------------
alter table public.jobs
  add column if not exists quote_count int not null default 0,
  add column if not exists accepted_quote_id uuid,
  add column if not exists job_date date,
  add column if not exists postcode_district text,
  add column if not exists photo_urls text[] not null default '{}',
  add column if not exists lat double precision,
  add column if not exists lng double precision,
  add column if not exists access_token uuid not null default gen_random_uuid(),
  add column if not exists updated_at timestamptz not null default now();

create unique index if not exists jobs_access_token_key on public.jobs (access_token);
create index if not exists jobs_status_created_idx on public.jobs (status, created_at desc);

alter table public.jobs drop constraint if exists jobs_status_check;
alter table public.jobs add constraint jobs_status_check
  check (status in ('open', 'full', 'accepted', 'completed', 'cancelled'));
alter table public.jobs drop constraint if exists jobs_coords_check;
alter table public.jobs add constraint jobs_coords_check
  check (
    (lat is null and lng is null)
    or (lat between 49.8 and 60.95 and lng between -8.7 and 1.8)
  );
alter table public.jobs drop constraint if exists jobs_photo_count_check;
alter table public.jobs add constraint jobs_photo_count_check
  check (coalesce(array_length(photo_urls, 1), 0) <= 8);

-- Safe columns are readable by businesses; access_token and exact coords are not.
grant select (quote_count, accepted_quote_id, job_date, postcode_district, photo_urls, updated_at)
  on public.jobs to authenticated;
-- Customers posting a job may supply these extra fields (coords come from postcodes.io).
grant insert (job_date, photo_urls, lat, lng) on public.jobs to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Job contacts: customer PII, readable only by the winning business
-- ---------------------------------------------------------------------------
create table if not exists public.job_contacts (
  job_id uuid primary key references public.jobs (id) on delete cascade,
  customer_name text,
  customer_email text,
  customer_phone text,
  address text,
  created_at timestamptz not null default now()
);
alter table public.job_contacts enable row level security;
revoke all on public.job_contacts from anon, authenticated;
grant select on public.job_contacts to authenticated;

insert into public.job_contacts (job_id, customer_name, customer_email, customer_phone)
select id, customer_name, customer_email, customer_phone from public.jobs
on conflict (job_id) do nothing;

-- ---------------------------------------------------------------------------
-- Quotes
-- ---------------------------------------------------------------------------
create table if not exists public.quotes (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  price_pence int check (price_pence between 100 and 10000000),
  description text check (char_length(description) <= 2000),
  available_date date,
  message text check (char_length(message) <= 2000),
  status text not null default 'claimed'
    check (status in ('claimed', 'submitted', 'accepted', 'lost', 'expired', 'withdrawn')),
  claimed_at timestamptz not null default now(),
  submitted_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (job_id, business_id),
  check (status in ('claimed', 'expired', 'withdrawn') or price_pence is not null)
);
create index if not exists quotes_business_idx on public.quotes (business_id, status);
create index if not exists quotes_job_idx on public.quotes (job_id, status);

alter table public.jobs drop constraint if exists jobs_accepted_quote_fk;
alter table public.jobs add constraint jobs_accepted_quote_fk
  foreign key (accepted_quote_id) references public.quotes (id) on delete set null;

alter table public.quotes enable row level security;
revoke all on public.quotes from anon, authenticated;
grant select on public.quotes to authenticated;

-- ---------------------------------------------------------------------------
-- Messages (customer <-> business, per quote)
-- ---------------------------------------------------------------------------
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs (id) on delete cascade,
  quote_id uuid not null references public.quotes (id) on delete cascade,
  sender text not null check (sender in ('customer', 'business')),
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists messages_quote_idx on public.messages (quote_id, created_at);
alter table public.messages enable row level security;
revoke all on public.messages from anon, authenticated;
grant select on public.messages to authenticated;

-- ---------------------------------------------------------------------------
-- Success fees and refund requests
-- ---------------------------------------------------------------------------
create table if not exists public.success_fees (
  id uuid primary key default gen_random_uuid(),
  quote_id uuid not null unique references public.quotes (id) on delete restrict,
  business_id uuid not null references public.businesses (id) on delete restrict,
  amount_pence int not null check (amount_pence >= 0),
  stripe_payment_intent_id text unique,
  status text not null default 'pending'
    check (status in ('pending', 'paid', 'failed', 'refunded')),
  failure_reason text,
  refund_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists success_fees_business_idx on public.success_fees (business_id, status);
alter table public.success_fees enable row level security;
revoke all on public.success_fees from anon, authenticated;
grant select on public.success_fees to authenticated;

create table if not exists public.refund_requests (
  id uuid primary key default gen_random_uuid(),
  success_fee_id uuid not null references public.success_fees (id) on delete cascade,
  requested_by text not null check (requested_by in ('customer', 'business', 'admin')),
  reason text not null check (char_length(reason) between 1 and 2000),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  decided_by uuid references public.businesses (id),
  decided_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.refund_requests enable row level security;
revoke all on public.refund_requests from anon, authenticated;
grant select on public.refund_requests to authenticated;

-- ---------------------------------------------------------------------------
-- Reviews tied to a real job
-- ---------------------------------------------------------------------------
alter table public.reviews add column if not exists job_id uuid references public.jobs (id) on delete set null;
create unique index if not exists reviews_job_key on public.reviews (job_id) where job_id is not null;

-- ---------------------------------------------------------------------------
-- Helper functions
-- ---------------------------------------------------------------------------
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.businesses where id = auth.uid()), false);
$$;

create or replace function public.distance_miles(lat1 float8, lng1 float8, lat2 float8, lng2 float8)
returns float8 language sql immutable as $$
  select 3958.8 * 2 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)
  ));
$$;

-- Normalise postcode district, force safe defaults, and copy contacts on job insert.
create or replace function public.jobs_before_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.status := 'open';
  new.quote_count := 0;
  new.accepted_quote_id := null;
  new.created_at := now();
  new.updated_at := now();
  new.access_token := gen_random_uuid();
  new.postcode_district := nullif(upper(split_part(btrim(coalesce(new.postcode, '')), ' ', 1)), '');
  return new;
end;
$$;
drop trigger if exists jobs_before_insert on public.jobs;
create trigger jobs_before_insert before insert on public.jobs
  for each row execute function public.jobs_before_insert();

create or replace function public.jobs_after_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.job_contacts (job_id, customer_name, customer_email, customer_phone)
  values (new.id, new.customer_name, new.customer_email, new.customer_phone)
  on conflict (job_id) do nothing;
  return null;
end;
$$;
drop trigger if exists jobs_after_insert on public.jobs;
create trigger jobs_after_insert after insert on public.jobs
  for each row execute function public.jobs_after_insert();

update public.jobs
set postcode_district = nullif(upper(split_part(btrim(coalesce(postcode, '')), ' ', 1)), '')
where postcode_district is null;

-- Expire claims older than the hold window and recompute affected jobs.
create or replace function public.expire_stale_claims(p_job_id uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_hold int;
  v_max int;
begin
  select claim_hold_minutes, max_quotes_per_job into v_hold, v_max from public.platform_settings;

  with expired as (
    update public.quotes q
    set status = 'expired', updated_at = now()
    where q.status = 'claimed'
      and q.claimed_at < now() - make_interval(mins => v_hold)
      and (p_job_id is null or q.job_id = p_job_id)
    returning q.job_id
  )
  update public.jobs j
  set quote_count = (
        select count(*) from public.quotes q
        where q.job_id = j.id and q.status in ('claimed', 'submitted')
      ),
      status = case when j.status = 'full' then 'open' else j.status end,
      updated_at = now()
  where j.id in (select distinct job_id from expired);

  -- A job reopened above may still be full if other claims remain active.
  update public.jobs
  set status = 'full'
  where status = 'open' and quote_count >= v_max
    and (p_job_id is null or id = p_job_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Business-facing RPCs
-- ---------------------------------------------------------------------------
create or replace function public.set_coverage(
  p_postcode text, p_lat float8, p_lng float8, p_radius_miles int
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_business uuid := auth.uid();
begin
  if v_business is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  if p_radius_miles not in (5, 10, 15, 25, 40) then
    return jsonb_build_object('error', 'invalid_radius');
  end if;
  if p_lat is null or p_lng is null
     or p_lat not between 49.8 and 60.95 or p_lng not between -8.7 and 1.8 then
    return jsonb_build_object('error', 'invalid_location');
  end if;
  if p_postcode is null or char_length(btrim(p_postcode)) not between 2 and 8 then
    return jsonb_build_object('error', 'invalid_postcode');
  end if;

  update public.businesses
  set base_postcode = upper(btrim(p_postcode)),
      base_lat = p_lat,
      base_lng = p_lng,
      coverage_radius_miles = p_radius_miles
  where id = v_business;

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.job_feed()
returns table (
  id uuid,
  waste_type text,
  volume text,
  postcode_district text,
  town text,
  timing text,
  details text,
  budget text,
  job_date date,
  photo_urls text[],
  created_at timestamptz,
  distance_miles numeric,
  spots_left int,
  my_quote_id uuid,
  my_quote_status text
) language plpgsql security definer set search_path = public as $$
declare
  v_business uuid := auth.uid();
  v_lat float8;
  v_lng float8;
  v_radius int;
  v_max int;
begin
  if v_business is null then return; end if;

  perform public.expire_stale_claims(null);

  select base_lat, base_lng, coverage_radius_miles into v_lat, v_lng, v_radius
  from public.businesses where businesses.id = v_business;
  if v_lat is null then return; end if;

  select max_quotes_per_job into v_max from public.platform_settings;

  return query
  select j.id, j.waste_type::text, j.volume::text, j.postcode_district, j.town::text,
         j.timing::text, j.details::text, j.budget::text, j.job_date, j.photo_urls, j.created_at,
         round(public.distance_miles(v_lat, v_lng, j.lat, j.lng)::numeric, 1),
         greatest(v_max - j.quote_count, 0),
         q.id, q.status
  from public.jobs j
  left join public.quotes q on q.job_id = j.id and q.business_id = v_business
  where j.lat is not null
    and public.distance_miles(v_lat, v_lng, j.lat, j.lng) <= v_radius
    and (
      (j.status = 'open' and q.id is null)
      or (q.id is not null and q.status in ('claimed', 'submitted', 'accepted'))
    )
  order by j.created_at desc
  limit 100;
end;
$$;

create or replace function public.claim_quote_spot(p_job_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_business uuid := auth.uid();
  v_biz public.businesses%rowtype;
  v_job public.jobs%rowtype;
  v_settings public.platform_settings%rowtype;
  v_existing public.quotes%rowtype;
  v_quote_id uuid;
begin
  if v_business is null then return jsonb_build_object('error', 'not_authenticated'); end if;

  select * into v_settings from public.platform_settings;
  select * into v_biz from public.businesses where id = v_business;

  if v_biz.subscription_status is distinct from 'active'
     and v_biz.subscription_status is distinct from 'trialing' then
    return jsonb_build_object('error', 'membership_required');
  end if;
  if v_biz.has_unpaid_fee then return jsonb_build_object('error', 'unpaid_fee'); end if;
  if v_biz.base_lat is null then return jsonb_build_object('error', 'no_coverage'); end if;

  -- Row lock serialises concurrent claims on the same job.
  select * into v_job from public.jobs where id = p_job_id for update;
  if not found then return jsonb_build_object('error', 'job_not_found'); end if;

  perform public.expire_stale_claims(p_job_id);
  select * into v_job from public.jobs where id = p_job_id;

  select * into v_existing from public.quotes where job_id = p_job_id and business_id = v_business;
  if found then
    if v_existing.status in ('claimed', 'submitted', 'accepted') then
      return jsonb_build_object('ok', true, 'quote_id', v_existing.id, 'status', v_existing.status,
        'expires_at', v_existing.claimed_at + make_interval(mins => v_settings.claim_hold_minutes));
    end if;
    return jsonb_build_object('error', 'already_quoted');
  end if;

  if v_job.status <> 'open' or v_job.quote_count >= v_settings.max_quotes_per_job then
    return jsonb_build_object('error', 'job_full');
  end if;
  if v_job.lat is null
     or public.distance_miles(v_biz.base_lat, v_biz.base_lng, v_job.lat, v_job.lng) > v_biz.coverage_radius_miles then
    return jsonb_build_object('error', 'out_of_area');
  end if;

  insert into public.quotes (job_id, business_id) values (p_job_id, v_business)
  returning id into v_quote_id;

  update public.jobs
  set quote_count = quote_count + 1,
      status = case when quote_count + 1 >= v_settings.max_quotes_per_job then 'full' else status end,
      updated_at = now()
  where id = p_job_id;

  return jsonb_build_object('ok', true, 'quote_id', v_quote_id, 'status', 'claimed',
    'expires_at', now() + make_interval(mins => v_settings.claim_hold_minutes));
end;
$$;

create or replace function public.submit_quote(
  p_quote_id uuid, p_price_pence int, p_description text, p_available_date date, p_message text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_business uuid := auth.uid();
  v_quote public.quotes%rowtype;
  v_hold int;
begin
  if v_business is null then return jsonb_build_object('error', 'not_authenticated'); end if;
  if p_price_pence is null or p_price_pence not between 100 and 10000000 then
    return jsonb_build_object('error', 'invalid_price');
  end if;
  if p_description is null or char_length(btrim(p_description)) not between 1 and 2000 then
    return jsonb_build_object('error', 'invalid_description');
  end if;
  if p_message is not null and char_length(p_message) > 2000 then
    return jsonb_build_object('error', 'invalid_message');
  end if;
  if p_available_date is not null and p_available_date < current_date then
    return jsonb_build_object('error', 'invalid_date');
  end if;

  select claim_hold_minutes into v_hold from public.platform_settings;

  select * into v_quote from public.quotes
  where id = p_quote_id and business_id = v_business for update;
  if not found then return jsonb_build_object('error', 'quote_not_found'); end if;
  if v_quote.status <> 'claimed' then return jsonb_build_object('error', 'not_claimable'); end if;

  if v_quote.claimed_at < now() - make_interval(mins => v_hold) then
    perform public.expire_stale_claims(v_quote.job_id);
    return jsonb_build_object('error', 'claim_expired');
  end if;

  update public.quotes
  set price_pence = p_price_pence,
      description = btrim(p_description),
      available_date = p_available_date,
      message = nullif(btrim(coalesce(p_message, '')), ''),
      status = 'submitted',
      submitted_at = now(),
      updated_at = now()
  where id = p_quote_id;

  return jsonb_build_object('ok', true, 'quote_id', p_quote_id);
end;
$$;

create or replace function public.withdraw_quote(p_quote_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_business uuid := auth.uid();
  v_quote public.quotes%rowtype;
begin
  if v_business is null then return jsonb_build_object('error', 'not_authenticated'); end if;

  select * into v_quote from public.quotes
  where id = p_quote_id and business_id = v_business;
  if not found then return jsonb_build_object('error', 'quote_not_found'); end if;
  if v_quote.status not in ('claimed', 'submitted') then
    return jsonb_build_object('error', 'not_withdrawable');
  end if;

  perform 1 from public.jobs where id = v_quote.job_id for update;

  update public.quotes set status = 'withdrawn', updated_at = now() where id = p_quote_id;
  update public.jobs
  set quote_count = greatest(quote_count - 1, 0),
      status = case when status = 'full' then 'open' else status end,
      updated_at = now()
  where id = v_quote.job_id;

  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- RLS policies
-- ---------------------------------------------------------------------------
drop policy if exists quotes_own_select on public.quotes;
create policy quotes_own_select on public.quotes
  for select to authenticated using (business_id = auth.uid() or public.is_admin());

drop policy if exists job_contacts_winner_select on public.job_contacts;
create policy job_contacts_winner_select on public.job_contacts
  for select to authenticated using (
    public.is_admin()
    or exists (
      select 1 from public.quotes q
      where q.job_id = job_contacts.job_id
        and q.business_id = auth.uid()
        and q.status = 'accepted'
    )
  );

drop policy if exists messages_own_select on public.messages;
create policy messages_own_select on public.messages
  for select to authenticated using (
    public.is_admin()
    or exists (select 1 from public.quotes q where q.id = messages.quote_id and q.business_id = auth.uid())
  );

drop policy if exists success_fees_own_select on public.success_fees;
create policy success_fees_own_select on public.success_fees
  for select to authenticated using (business_id = auth.uid() or public.is_admin());

drop policy if exists refund_requests_own_select on public.refund_requests;
create policy refund_requests_own_select on public.refund_requests
  for select to authenticated using (
    public.is_admin()
    or exists (
      select 1 from public.success_fees f
      where f.id = refund_requests.success_fee_id and f.business_id = auth.uid()
    )
  );

-- ---------------------------------------------------------------------------
-- Function execute permissions
-- ---------------------------------------------------------------------------
revoke execute on function public.expire_stale_claims(uuid) from public, anon, authenticated;
revoke execute on function public.jobs_before_insert() from public, anon, authenticated;
revoke execute on function public.jobs_after_insert() from public, anon, authenticated;

revoke execute on function public.set_coverage(text, float8, float8, int) from public, anon;
revoke execute on function public.job_feed() from public, anon;
revoke execute on function public.claim_quote_spot(uuid) from public, anon;
revoke execute on function public.submit_quote(uuid, int, text, date, text) from public, anon;
revoke execute on function public.withdraw_quote(uuid) from public, anon;

grant execute on function public.set_coverage(text, float8, float8, int) to authenticated;
grant execute on function public.job_feed() to authenticated;
grant execute on function public.claim_quote_spot(uuid) to authenticated;
grant execute on function public.submit_quote(uuid, int, text, date, text) to authenticated;
grant execute on function public.withdraw_quote(uuid) to authenticated;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.distance_miles(float8, float8, float8, float8) to anon, authenticated;
