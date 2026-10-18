-- Customer side of the quote lifecycle: post a job and get a private link,
-- view quotes via that link, and accept one (acceptance only via the
-- customer-job edge function, which then charges the success fee).

create or replace function public.post_job(
  p_waste_type text, p_volume text, p_postcode text, p_timing text,
  p_details text, p_budget text,
  p_customer_name text, p_customer_email text, p_customer_phone text
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_token uuid;
begin
  if coalesce(btrim(p_customer_email), '') = '' or position('@' in p_customer_email) = 0 then
    raise exception 'email_required';
  end if;
  if coalesce(btrim(p_postcode), '') = '' then
    raise exception 'postcode_required';
  end if;

  insert into public.jobs (waste_type, volume, postcode, timing, details, budget,
                           customer_name, customer_email, customer_phone, status)
  values (left(p_waste_type, 200), left(p_volume, 200), left(btrim(p_postcode), 12), left(p_timing, 200),
          left(p_details, 2000), left(p_budget, 200),
          left(btrim(p_customer_name), 200), left(lower(btrim(p_customer_email)), 320),
          left(btrim(p_customer_phone), 40), 'open')
  returning id, access_token into v_id, v_token;

  return jsonb_build_object('id', v_id, 'token', v_token);
end;
$$;
revoke all on function public.post_job(text, text, text, text, text, text, text, text, text) from public;
grant execute on function public.post_job(text, text, text, text, text, text, text, text, text) to anon, authenticated;

create or replace function public.customer_job_view(p_job_id uuid, p_token uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_job public.jobs%rowtype;
begin
  select * into v_job from public.jobs where id = p_job_id and access_token = p_token;
  if not found then raise exception 'job_not_found'; end if;

  return jsonb_build_object(
    'job', jsonb_build_object(
      'id', v_job.id, 'waste_type', v_job.waste_type, 'volume', v_job.volume,
      'postcode', v_job.postcode, 'timing', v_job.timing, 'details', v_job.details,
      'status', v_job.status, 'quote_count', v_job.quote_count,
      'accepted_quote_id', v_job.accepted_quote_id,
      'customer_name', v_job.customer_name,
      'customer_went_ahead', v_job.customer_went_ahead,
      'customer_confirmed_at', v_job.customer_confirmed_at,
      'created_at', v_job.created_at
    ),
    'quotes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', q.id, 'status', q.status, 'price_pence', q.price_pence,
        'description', q.description, 'available_date', q.available_date,
        'message', q.message, 'submitted_at', q.submitted_at,
        'business_name', b.business_name, 'town', b.town, 'verified', b.verified,
        'contact_name', case when q.status = 'accepted' then b.contact_name end,
        'phone', case when q.status = 'accepted' then b.phone end,
        'email', case when q.status = 'accepted' then b.email end
      ) order by q.price_pence)
      from public.quotes q join public.businesses b on b.id = q.business_id
      where q.job_id = v_job.id and q.status in ('submitted', 'accepted', 'lost')
    ), '[]'::jsonb)
  );
end;
$$;
revoke all on function public.customer_job_view(uuid, uuid) from public;
grant execute on function public.customer_job_view(uuid, uuid) to anon, authenticated;

create or replace function public.accept_quote(p_job_id uuid, p_token uuid, p_quote_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_job public.jobs%rowtype;
  v_quote public.quotes%rowtype;
begin
  select * into v_job from public.jobs
   where id = p_job_id and access_token = p_token for update;
  if not found then raise exception 'job_not_found'; end if;

  if v_job.status = 'accepted' and v_job.accepted_quote_id = p_quote_id then
    return jsonb_build_object('quote_id', p_quote_id, 'already_accepted', true);
  end if;
  if v_job.status not in ('open', 'full') then raise exception 'job_not_open'; end if;

  select * into v_quote from public.quotes
   where id = p_quote_id and job_id = p_job_id for update;
  if not found then raise exception 'quote_not_found'; end if;
  if v_quote.status <> 'submitted' then raise exception 'quote_not_available'; end if;

  update public.quotes set status = 'accepted', updated_at = now() where id = p_quote_id;
  update public.quotes set status = 'lost', updated_at = now()
   where job_id = p_job_id and id <> p_quote_id and status = 'submitted';
  update public.quotes set status = 'expired', updated_at = now()
   where job_id = p_job_id and status = 'claimed';

  update public.jobs
     set status = 'accepted', accepted_quote_id = p_quote_id, updated_at = now()
   where id = p_job_id;

  return jsonb_build_object('quote_id', p_quote_id, 'business_id', v_quote.business_id,
                            'already_accepted', false);
end;
$$;
revoke all on function public.accept_quote(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.accept_quote(uuid, uuid, uuid) to service_role;
