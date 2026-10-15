-- Admin views for success fees / flagged customers, and the server-side helper
-- the charge-success-fee edge function uses to create a fee for an accepted quote.

create or replace function public.admin_list_fees()
returns table (
  id uuid,
  quote_id uuid,
  business_id uuid,
  business_name text,
  business_email text,
  amount_pence integer,
  credit_applied_pence integer,
  status text,
  failure_reason text,
  credited_at timestamptz,
  credit_reason text,
  created_at timestamptz,
  job_id uuid,
  waste_type text,
  town text,
  postcode_district text
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  return query
    select f.id, f.quote_id, f.business_id, b.business_name, b.email,
           f.amount_pence, f.credit_applied_pence, f.status, f.failure_reason,
           f.credited_at, f.credit_reason, f.created_at,
           j.id, j.waste_type, j.town, j.postcode_district
      from public.success_fees f
      join public.businesses b on b.id = f.business_id
      left join public.quotes q on q.id = f.quote_id
      left join public.jobs j on j.id = q.job_id
     order by f.created_at desc
     limit 500;
end;
$$;
revoke all on function public.admin_list_fees() from public, anon;
grant execute on function public.admin_list_fees() to authenticated;

create or replace function public.create_success_fee(p_quote_id uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_quote public.quotes%rowtype;
  v_s public.platform_settings%rowtype;
  v_amount integer;
  v_id uuid;
begin
  select * into v_quote from public.quotes where id = p_quote_id;
  if not found then raise exception 'quote_not_found'; end if;
  if v_quote.status <> 'accepted' then raise exception 'quote_not_accepted'; end if;
  if coalesce(v_quote.price_pence, 0) <= 0 then raise exception 'quote_has_no_price'; end if;

  select * into v_s from public.platform_settings limit 1;
  v_amount := round(v_quote.price_pence * coalesce(v_s.fee_percent, 12) / 100.0);
  v_amount := greatest(v_amount, coalesce(v_s.fee_min_pence, 0));
  if v_s.fee_max_pence is not null then v_amount := least(v_amount, v_s.fee_max_pence); end if;

  insert into public.success_fees (quote_id, business_id, amount_pence, status)
  values (p_quote_id, v_quote.business_id, v_amount, 'pending')
  on conflict (quote_id) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from public.success_fees where quote_id = p_quote_id;
  end if;
  return v_id;
end;
$$;
revoke all on function public.create_success_fee(uuid) from public, anon, authenticated;
grant execute on function public.create_success_fee(uuid) to service_role;
