-- Jobs need a map location to appear in a business's lead feed (job_feed and
-- claim_quote_spot both filter by distance). The homepage geocodes the postcode
-- and passes lat/lng/town; coordinates outside the UK are discarded.
drop function if exists public.post_job(text, text, text, text, text, text, text, text, text);

create or replace function public.post_job(
  p_waste_type text, p_volume text, p_postcode text, p_timing text,
  p_details text, p_budget text,
  p_customer_name text, p_customer_email text, p_customer_phone text,
  p_lat double precision default null, p_lng double precision default null, p_town text default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_token uuid;
  v_ok_location boolean := p_lat between 49.8 and 60.95 and p_lng between -8.7 and 1.8;
begin
  if coalesce(btrim(p_customer_email), '') = '' or position('@' in p_customer_email) = 0 then
    raise exception 'email_required';
  end if;
  if coalesce(btrim(p_postcode), '') = '' then
    raise exception 'postcode_required';
  end if;

  insert into public.jobs (waste_type, volume, postcode, timing, details, budget,
                           customer_name, customer_email, customer_phone, status,
                           lat, lng, town)
  values (left(p_waste_type, 200), left(p_volume, 200), left(upper(btrim(p_postcode)), 12), left(p_timing, 200),
          left(p_details, 2000), left(p_budget, 200),
          left(btrim(p_customer_name), 200), left(lower(btrim(p_customer_email)), 320),
          left(btrim(p_customer_phone), 40), 'open',
          case when v_ok_location then p_lat end,
          case when v_ok_location then p_lng end,
          nullif(left(btrim(coalesce(p_town, '')), 100), ''))
  returning id, access_token into v_id, v_token;

  return jsonb_build_object('id', v_id, 'token', v_token);
end;
$$;
revoke all on function public.post_job(text, text, text, text, text, text, text, text, text, double precision, double precision, text) from public;
grant execute on function public.post_job(text, text, text, text, text, text, text, text, text, double precision, double precision, text) to anon, authenticated;
