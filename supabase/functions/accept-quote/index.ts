// Public endpoint used by the customer quotes page. The customer proves they own
// the job with its private access token, then the quote is accepted and the
// winning business is charged its success fee (credit first, then card).
// A failed charge never undoes the customer's acceptance — it is flagged on the
// fee and the business instead, so an admin can follow up.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(supabaseUrl, serviceKey);

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CUSTOMER_ERRORS: Record<string, [number, string]> = {
  job_not_found: [404, "We couldn't find that job. Check the link from your confirmation."],
  job_not_open: [409, "This job is no longer accepting quotes."],
  quote_not_found: [404, "That quote no longer exists."],
  quote_not_available: [409, "That quote is no longer available."],
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let body: { jobId?: string; token?: string; quoteId?: string };
  try { body = await req.json(); } catch { return json({ error: "invalid_json" }, 400); }
  const { jobId, token, quoteId } = body;
  if (![jobId, token, quoteId].every((v) => typeof v === "string" && UUID.test(v))) {
    return json({ error: "invalid_request", message: "Missing or invalid job link." }, 400);
  }

  const { data: accepted, error } = await supabase.rpc("accept_quote", {
    p_job_id: jobId, p_token: token, p_quote_id: quoteId,
  });
  if (error) {
    const key = Object.keys(CUSTOMER_ERRORS).find((k) => error.message.includes(k));
    if (key) return json({ error: key, message: CUSTOMER_ERRORS[key][1] }, CUSTOMER_ERRORS[key][0]);
    console.error("accept_quote failed:", error);
    return json({ error: "accept_failed", message: "Something went wrong. Please try again." }, 500);
  }

  // Charging is internal: its outcome is logged and stored, never shown to the customer.
  // Already-paid fees are a no-op inside charge-success-fee, so repeat clicks are safe.
  try {
    const res = await fetch(`${supabaseUrl}/functions/v1/charge-success-fee`, {
      method: "POST",
      headers: { Authorization: `Bearer ${serviceKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ quoteId }),
    });
    const result = await res.json().catch(() => ({}));
    if (!res.ok || result.status !== "paid") console.warn("Success fee not collected:", quoteId, result);
  } catch (err) {
    console.error("Calling charge-success-fee failed:", quoteId, err);
  }

  const { data: view } = await supabase.rpc("customer_job_view", { p_job_id: jobId, p_token: token });
  return json({ accepted: true, alreadyAccepted: accepted?.already_accepted ?? false, view });
});
