-- =============================================================================
-- Rubbleit security hardening — APPLIED to production project bfekeamjuiytiiexbflt
-- =============================================================================
-- Context: base-table RLS with owner-scoped policies already existed. The two
-- remaining holes were column-level:
--   1. businesses_owner_update allowed the owner to write ANY column (credits).
--   2. jobs_business_select used qual=true, exposing customer contact columns.
-- This migration closes both with column privileges + SECURITY DEFINER functions.
-- It is idempotent and deletes no data.

-- 1. Free-trial ledger entry written server-side by a trigger, not the client
create or replace function public.grant_free_trial_ledger()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.credit_transactions(business_id, amount, type)
  values (new.id, coalesce(new.credits, 0), 'free_trial');
  return new;
end;
$$;

drop trigger if exists on_business_created on public.businesses;
create trigger on_business_created
  after insert on public.businesses
  for each row execute function public.grant_free_trial_ledger();

-- 2. Businesses: clients may NOT write credits / verified / is_featured / featured_until / stripe_customer_id
revoke insert, update on public.businesses from anon, authenticated;
grant insert (id, email, business_name, contact_name, phone, postcode, town, licence_number)
  on public.businesses to authenticated;
grant update (business_name, contact_name, phone, postcode, town, licence_number)
  on public.businesses to authenticated;

-- 3. Credit ledger is append-only by trusted (definer) code only
revoke insert, update, delete on public.credit_transactions from anon, authenticated;

-- 4. Hide customer contact columns on jobs from all direct client reads
revoke select on public.jobs from anon, authenticated;
grant select (id, waste_type, volume, postcode, town, timing, details, budget, status, created_at)
  on public.jobs to anon, authenticated;

-- 5. Atomic, trusted unlock: verify -> charge -> record -> return contact
create or replace function public.unlock_lead(p_job_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_business uuid := auth.uid();
  v_cost int := 1;
  v_credits int;
  v_contact jsonb;
begin
  if v_business is null then return jsonb_build_object('error','not_authenticated'); end if;
  if not exists (select 1 from public.jobs where id = p_job_id) then
    return jsonb_build_object('error','job_not_found');
  end if;

  if exists (select 1 from public.lead_unlocks where business_id = v_business and job_id = p_job_id) then
    select jsonb_build_object('customer_name',customer_name,'customer_email',customer_email,'customer_phone',customer_phone)
      into v_contact from public.jobs where id = p_job_id;
    select credits into v_credits from public.businesses where id = v_business;
    return jsonb_build_object('credits_remaining', v_credits, 'already_unlocked', true, 'contact', v_contact);
  end if;

  select credits into v_credits from public.businesses where id = v_business for update;
  if v_credits is null then return jsonb_build_object('error','no_business'); end if;
  if v_credits < v_cost then
    return jsonb_build_object('error','insufficient_credits','credits_remaining',v_credits);
  end if;

  update public.businesses set credits = credits - v_cost where id = v_business;
  insert into public.lead_unlocks(business_id, job_id, credits_spent) values (v_business, p_job_id, v_cost);
  insert into public.credit_transactions(business_id, amount, type) values (v_business, -v_cost, 'spend');

  select jsonb_build_object('customer_name',customer_name,'customer_email',customer_email,'customer_phone',customer_phone)
    into v_contact from public.jobs where id = p_job_id;
  return jsonb_build_object('credits_remaining', v_credits - v_cost, 'contact', v_contact);
end;
$$;

-- 6. Contact details for leads this business has already paid to unlock
create or replace function public.my_unlocked_leads()
returns table(job_id uuid, customer_name text, customer_email text, customer_phone text)
language sql security definer set search_path = public as $$
  select j.id, j.customer_name, j.customer_email, j.customer_phone
  from public.lead_unlocks lu
  join public.jobs j on j.id = lu.job_id
  where lu.business_id = auth.uid();
$$;

revoke all on function public.unlock_lead(uuid) from public, anon;
revoke all on function public.my_unlocked_leads() from public, anon;
grant execute on function public.unlock_lead(uuid) to authenticated;
grant execute on function public.my_unlocked_leads() to authenticated;
