// Creates a Stripe Checkout Session for the Rubble membership. Old credit packs
// are retired, so any other plan id is rejected.
// Prices live ONLY on the server, so the client can never change the amount.
import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";

const MEMBERSHIP_LOOKUP_KEY = "rubble_membership_monthly";

// The stored price ID only exists in one Stripe account. If the function's key
// points at a different account, find (or create) the price there by lookup key.
async function ensureMembershipPrice(stripe: Stripe, storedId: string | null): Promise<string> {
  if (storedId) {
    try {
      const p = await stripe.prices.retrieve(storedId);
      if (p.active) return p.id;
    } catch { /* not in this account */ }
  }
  const found = await stripe.prices.list({ lookup_keys: [MEMBERSHIP_LOOKUP_KEY], active: true, limit: 1 });
  if (found.data[0]) return found.data[0].id;

  const product = await stripe.products.create(
    { name: "Rubble membership", description: "Quote on local jobs. 12% success fee only when you win." },
    { idempotencyKey: "rubble-membership-product-v1" },
  );
  const price = await stripe.prices.create(
    {
      product: product.id,
      currency: "gbp",
      unit_amount: 2900,
      recurring: { interval: "month" },
      lookup_key: MEMBERSHIP_LOOKUP_KEY,
      transfer_lookup_key: true,
    },
    { idempotencyKey: "rubble-membership-price-v1" },
  );
  return price.id;
}

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

    const { packId, origin } = await req.json();
    const base = (typeof origin === "string" && /^https?:\/\//.test(origin)) ? origin.replace(/\/$/, "") : "";

    const { data: biz } = await supabase.from("businesses")
      .select("email, business_name, stripe_customer_id, subscription_status, trial_ends_at")
      .eq("id", user.id).maybeSingle();
    if (!biz) return json({ error: "business_not_found" }, 404);

    // One Stripe customer per business, reused for membership and success fees.
    let customerId = biz.stripe_customer_id as string | null;
    if (!customerId) {
      const customer = await stripe.customers.create(
        { email: biz.email ?? user.email ?? undefined, name: biz.business_name || undefined, metadata: { business_id: user.id } },
        { idempotencyKey: `customer-${user.id}` },
      );
      customerId = customer.id;
      await supabase.from("businesses").update({ stripe_customer_id: customerId }).eq("id", user.id);
    }

    const successUrl = `${base}/rubble-dashboard.html?checkout=success`;
    const cancelUrl = `${base}/rubble-dashboard.html?checkout=cancelled`;

    if (packId === "membership") {
      if (biz.subscription_status === "active" || biz.subscription_status === "trialing" || biz.subscription_status === "past_due") {
        return json({ error: "already_member" }, 409);
      }

      const { data: settings } = await supabase.from("platform_settings")
        .select("membership_price_id, trial_days").single();
      const priceId = await ensureMembershipPrice(stripe, settings?.membership_price_id ?? null);

      // Only one free trial per business, even if they cancel and rejoin.
      const trialDays = biz.trial_ends_at ? 0 : (settings?.trial_days ?? 30);

      const session = await stripe.checkout.sessions.create({
        mode: "subscription",
        customer: customerId,
        client_reference_id: user.id,
        line_items: [{ price: priceId, quantity: 1 }],
        payment_method_collection: "always",
        subscription_data: {
          ...(trialDays > 0 ? { trial_period_days: trialDays } : {}),
          metadata: { business_id: user.id, pack_id: "membership" },
        },
        metadata: { business_id: user.id, pack_id: "membership" },
        success_url: successUrl,
        cancel_url: cancelUrl,
      });
      return json({ url: session.url });
    }

    return json({ error: "unknown_plan" }, 400);
  } catch (err) {
    console.error("create-checkout error:", err);
    return json({ error: (err as Error).message }, 500);
  }
});
