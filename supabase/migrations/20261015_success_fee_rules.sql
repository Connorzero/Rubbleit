-- Success fee rules: fees are final once a customer accepts a quote.
-- Admins can issue account credit for fake/spam/duplicate jobs; no cash refunds.
-- Customers who say "no, it didn't go ahead" on 2+ accepted jobs are flagged
-- and blocked from posting until an admin reviews them.

-- 1. Fees are non-refundable --------------------------------------------------
drop table if exists public.refund_requests;

alter table public.success_fees drop constraint if exists success_fees_status_check;
alter table public.success_fees
  add constraint success_fees_status_check check (status in ('pending', 'paid', 'failed'));

alter table public.success_fees
  drop column if exists refund_reason,
  add column if not exists credited_at timestamptz,
  add column if not exists credit_reason text,
  add column if not exists credit_applied_pence integer not null default 0
    check (credit_applied_pence >= 0);

-- 2. Fee credit balance + ledger -----------------------------------------------
alter table public.businesses
  add column if not exists fee_credit_pence integer not null default 0
    check (fee_credit_pence >= 0);

-- Businesses can update parts of their own row, so block direct edits to the
-- credit balance. Only the security-definer functions below may change it.
create or replace function public.guard_fee_credit()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.fee_credit_pence is distinct from old.fee_credit_pence
     and coalesce(current_setting('rubble.fee_credit_write', true), '') <> 'on' then
    raise exception 'fee_credit_pence is read-only';
  end if;
  return new;
end;
$$;

drop trigger if exists businesses_guard_fee_credit on public.businesses;
create trigger businesses_guard_fee_credit
  before update on public.businesses
  for each row execute function public.guard_fee_credit();

create table if not exists public.fee_credit_ledger (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  success_fee_id uuid references public.success_fees (id) on delete set null,
  delta_pence integer not null check (delta_pence <> 0),
  kind text not null check (kind in ('issued', 'applied')),
  reason text,
  created_by uuid,
  created_at timestamptz not null default now()
);
create unique index if not exists fee_credit_one_issue_per_fee
  on public.fee_credit_ledger (success_fee_id) where kind = 'issued';
create index if not exists fee_credit_ledger_business_idx
  on public.fee_credit_ledger (business_id, created_at desc);

alter table public.fee_credit_ledger enable row level security;
revoke all on public.fee_credit_ledger from anon, authenticated;
grant select on public.fee_credit_ledger to authenticated;
drop policy if exists fee_credit_ledger_select on public.fee_credit_ledger;
create policy fee_credit_ledger_select on public.fee_credit_ledger
  for select to authenticated using (business_id = auth.uid() or public.is_admin());

-- Admin only: credit a paid success fee back to the business as account credit.
create or replace function public.issue_fee_credit(p_fee_id uuid, p_reason text)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_fee public.success_fees%rowtype;
  v_balance integer;
begin
  if not public.is_admin() then
    raise exception 'not_admin';
  end if;
  if p_reason not in ('fake', 'spam', 'duplicate') then
    raise exception 'invalid_reason';
  end if;

  select * into v_fee from public.success_fees where id = p_fee_id for update;
  if not found then raise exception 'fee_not_found'; end if;
  if v_fee.status <> 'paid' then raise exception 'fee_not_paid'; end if;
  if v_fee.credited_at is not null then raise exception 'already_credited'; end if;

  update public.success_fees
     set credited_at = now(), credit_reason = p_reason, updated_at = now()
   where id = p_fee_id;

  insert into public.fee_credit_ledger (business_id, success_fee_id, delta_pence, kind, reason, created_by)
  values (v_fee.business_id, p_fee_id, v_fee.amount_pence, 'issued', p_reason, auth.uid());

  perform set_config('rubble.fee_credit_write', 'on', true);
  update public.businesses
     set fee_credit_pence = fee_credit_pence + v_fee.amount_pence
   where id = v_fee.business_id
  returning fee_credit_pence into v_balance;

  return v_balance;
end;
$$;

-- Server only (fee charging code): spends available credit on a pending fee
-- and returns the pence still to charge to the card.
create or replace function public.apply_fee_credit(p_fee_id uuid)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_fee public.success_fees%rowtype;
  v_credit integer;
  v_use integer;
begin
  select * into v_fee from public.success_fees where id = p_fee_id for update;
  if not found then raise exception 'fee_not_found'; end if;
  if v_fee.status <> 'pending' then
    return 0;
  end if;

  select fee_credit_pence into v_credit from public.businesses
   where id = v_fee.business_id for update;

  v_use := least(coalesce(v_credit, 0), v_fee.amount_pence - v_fee.credit_applied_pence);
  if v_use > 0 then
    perform set_config('rubble.fee_credit_write', 'on', true);
    update public.businesses set fee_credit_pence = fee_credit_pence - v_use
     where id = v_fee.business_id;
    update public.success_fees
       set credit_applied_pence = credit_applied_pence + v_use, updated_at = now()
     where id = p_fee_id;
    insert into public.fee_credit_ledger (business_id, success_fee_id, delta_pence, kind)
    values (v_fee.business_id, p_fee_id, -v_use, 'applied');
  end if;

  return v_fee.amount_pence - v_fee.credit_applied_pence - greatest(v_use, 0);
end;
$$;

revoke all on function public.issue_fee_credit(uuid, text) from public, anon;
grant execute on function public.issue_fee_credit(uuid, text) to authenticated;
revoke all on function public.apply_fee_credit(uuid) from public, anon, authenticated;
grant execute on function public.apply_fee_credit(uuid) to service_role;

-- 3. Unreliable customer flagging ----------------------------------------------
create or replace function public.normalize_uk_phone(p text)
returns text language sql immutable as $$
  select nullif(regexp_replace(regexp_replace(coalesce(p, ''), '\D', '', 'g'), '^44', '0'), '');
$$;

create table if not exists public.customer_flags (
  phone_normalized text primary key,
  last_email text,
  no_count integer not null default 0,
  flagged_at timestamptz,
  reviewed_at timestamptz,
  reviewed_by uuid,
  review_note text,
  updated_at timestamptz not null default now()
);
alter table public.customer_flags enable row level security;
revoke all on public.customer_flags from anon, authenticated;
grant select on public.customer_flags to authenticated;
drop policy if exists customer_flags_admin_select on public.customer_flags;
create policy customer_flags_admin_select on public.customer_flags
  for select to authenticated using (public.is_admin());

alter table public.jobs
  add column if not exists customer_went_ahead boolean,
  add column if not exists customer_confirmed_at timestamptz;

-- Customer answers "did the job go ahead?" via the private link (access token).
-- The answer never changes the success fee; a "no" only counts towards a flag.
create or replace function public.confirm_job_outcome(p_job_id uuid, p_token uuid, p_went_ahead boolean)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_job public.jobs%rowtype;
  v_phone text;
  v_email text;
  v_count integer;
begin
  select * into v_job from public.jobs
   where id = p_job_id and access_token = p_token for update;
  if not found then raise exception 'job_not_found'; end if;
  if v_job.status not in ('accepted', 'completed') then raise exception 'job_not_accepted'; end if;
  if v_job.customer_confirmed_at is not null then raise exception 'already_confirmed'; end if;

  update public.jobs
     set customer_went_ahead = p_went_ahead,
         customer_confirmed_at = now(),
         status = case when p_went_ahead then 'completed' else status end,
         updated_at = now()
   where id = p_job_id;

  if p_went_ahead then return 'thanks'; end if;

  select coalesce(c.customer_phone, v_job.customer_phone), coalesce(c.customer_email, v_job.customer_email)
    into v_phone, v_email
    from (select 1) d left join public.job_contacts c on c.job_id = p_job_id;
  v_phone := public.normalize_uk_phone(v_phone);
  if v_phone is null then return 'recorded'; end if;

  insert into public.customer_flags (phone_normalized, last_email, no_count)
  values (v_phone, v_email, 1)
  on conflict (phone_normalized) do update
     set no_count = customer_flags.no_count + 1,
         last_email = coalesce(excluded.last_email, customer_flags.last_email),
         updated_at = now()
  returning no_count into v_count;

  if v_count >= 2 then
    update public.customer_flags
       set flagged_at = now(), reviewed_at = null, reviewed_by = null
     where phone_normalized = v_phone and (flagged_at is null or reviewed_at is not null);
  end if;
  return 'recorded';
end;
$$;
revoke all on function public.confirm_job_outcome(uuid, uuid, boolean) from public;
grant execute on function public.confirm_job_outcome(uuid, uuid, boolean) to anon, authenticated;

-- Admin clears a flag after review. The count resets, so two more "no"
-- answers will flag the customer again.
create or replace function public.review_customer_flag(p_phone text, p_note text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  update public.customer_flags
     set reviewed_at = now(), reviewed_by = auth.uid(), review_note = p_note,
         no_count = 0, updated_at = now()
   where phone_normalized = public.normalize_uk_phone(p_phone);
end;
$$;
revoke all on function public.review_customer_flag(text, text) from public, anon;
grant execute on function public.review_customer_flag(text, text) to authenticated;

-- Block flagged customers from posting new jobs until reviewed.
create or replace function public.jobs_before_insert()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (
    select 1 from public.customer_flags f
     where f.flagged_at is not null and f.reviewed_at is null
       and (f.phone_normalized = public.normalize_uk_phone(new.customer_phone)
            or (f.last_email is not null and lower(f.last_email) = lower(btrim(coalesce(new.customer_email, '')))))
  ) then
    raise exception 'customer_under_review' using errcode = 'P0001';
  end if;

  new.status := 'open';
  new.quote_count := 0;
  new.accepted_quote_id := null;
  new.created_at := now();
  new.updated_at := now();
  new.access_token := gen_random_uuid();
  new.postcode_district := nullif(upper(split_part(btrim(coalesce(new.postcode, '')), ' ', 1)), '');
  new.customer_went_ahead := null;
  new.customer_confirmed_at := null;
  return new;
end;
$$;
