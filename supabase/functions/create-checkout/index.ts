// Creates a Stripe Checkout Session for a credit pack or subscription.
// Prices live ONLY here on the server, so the client can never change the
// amount or which pack maps to how many credits.
import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";

// Source of truth for what each pack costs and grants.
// amountPence is what Stripe charges; credits is what the webhook grants.
const PACKS: Record<string, {
  name: string;
  amountPence: number;
  credits: number;
  mode: "payment" | "subscription";
  interval?: "month";
}> = {
  gravel: { name: "Gravel — 5 lead credits", amountPence: 2900, credits: 5, mode: "payment" },
  rubble: { name: "Rubble — 15 lead credits", amountPence: 7900, credits: 15, mode: "payment" },
  boulder: { name: "Boulder — unlimited leads (monthly)", amountPence: 2900, credits: 0, mode: "subscription", interval: "month" },
};

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { apiVersion: "2024-06-20" });
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // Identify the caller from their Supabase JWT — never trust a client-sent id
    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: userErr } = await supabase.auth.getUser(token);
    if (userErr || !user) {
      return new Response(JSON.stringify({ error: "not_authenticated" }), { status: 401, headers: { ...cors, "Content-Type": "application/json" } });
    }

    const { packId, origin } = await req.json();
    const pack = PACKS[packId];
    if (!pack) {
      return new Response(JSON.stringify({ error: "unknown_pack" }), { status: 400, headers: { ...cors, "Content-Type": "application/json" } });
    }

    const { data: biz } = await supabase.from("businesses").select("email, stripe_customer_id").eq("id", user.id).maybeSingle();
    const base = (typeof origin === "string" && origin.startsWith("http")) ? origin.replace(/\/$/, "") : "";

    const session = await stripe.checkout.sessions.create({
      mode: pack.mode,
      client_reference_id: user.id,
      customer: biz?.stripe_customer_id ?? undefined,
      customer_email: biz?.stripe_customer_id ? undefined : (biz?.email ?? user.email ?? undefined),
      line_items: [{
        quantity: 1,
        price_data: {
          currency: "gbp",
          unit_amount: pack.amountPence,
          product_data: { name: pack.name },
          ...(pack.mode === "subscription" ? { recurring: { interval: pack.interval! } } : {}),
        },
      }],
      metadata: { business_id: user.id, pack_id: packId, credits: String(pack.credits) },
      ...(pack.mode === "subscription"
        ? { subscription_data: { metadata: { business_id: user.id, pack_id: packId } } }
        : {}),
      success_url: `${base}/rubble-dashboard.html?checkout=success`,
      cancel_url: `${base}/rubble-dashboard.html?checkout=cancelled`,
    });

    return new Response(JSON.stringify({ url: session.url }), { headers: { ...cors, "Content-Type": "application/json" } });
  } catch (err) {
    console.error("create-checkout error:", err);
    return new Response(JSON.stringify({ error: (err as Error).message }), { status: 500, headers: { ...cors, "Content-Type": "application/json" } });
  }
});
