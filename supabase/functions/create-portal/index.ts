// Opens the Stripe Billing Portal so a business can update their card,
// see invoices, or cancel their membership.
import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { apiVersion: "2024-06-20" });
    const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    const token = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
    const { data: { user }, error: userErr } = await supabase.auth.getUser(token);
    if (userErr || !user) return json({ error: "not_authenticated" }, 401);

    const { origin } = await req.json().catch(() => ({}));
    const base = (typeof origin === "string" && /^https?:\/\//.test(origin)) ? origin.replace(/\/$/, "") : "";

    const { data: biz } = await supabase.from("businesses")
      .select("stripe_customer_id").eq("id", user.id).maybeSingle();
    if (!biz?.stripe_customer_id) return json({ error: "no_billing_account" }, 404);

    const session = await stripe.billingPortal.sessions.create({
      customer: biz.stripe_customer_id,
      return_url: `${base}/rubble-dashboard.html?portal=return`,
    });
    return json({ url: session.url });
  } catch (err) {
    console.error("create-portal error:", err);
    return json({ error: (err as Error).message }, 500);
  }
});
