// Stripe webhook: the ONLY place that grants credits or flips subscription
// state. Verifies the Stripe signature, then acts on verified events using the
// service-role key. Credit grants are idempotent via a unique index on
// credit_transactions.stripe_session_id, so a replayed event can't double-credit.
import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { apiVersion: "2024-06-20" });
const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);
const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET")!;

async function grantCredits(businessId: string, credits: number, sessionId: string) {
  // Idempotent insert — the unique index on stripe_session_id rejects replays
  const { error: insErr } = await supabase.from("credit_transactions").insert({
    business_id: businessId,
    amount: credits,
    type: "purchase",
    stripe_session_id: sessionId,
  });
  if (insErr) {
    if ((insErr as { code?: string }).code === "23505") {
      console.log("Duplicate webhook for session", sessionId, "- already credited, skipping");
      return;
    }
    throw insErr;
  }
  // Ledger row is unique to this session, so it's safe to bump the balance now
  const { data: biz, error: selErr } = await supabase.from("businesses").select("credits").eq("id", businessId).single();
  if (selErr) throw selErr;
  const { error: updErr } = await supabase.from("businesses")
    .update({ credits: (biz?.credits ?? 0) + credits }).eq("id", businessId);
  if (updErr) throw updErr;
  console.log(`Granted ${credits} credits to ${businessId} for ${sessionId}`);
}

async function setSubscription(businessId: string, status: string, periodEnd: number | null, customerId?: string) {
  const patch: Record<string, unknown> = { subscription_status: status };
  if (periodEnd) patch.subscription_current_period_end = new Date(periodEnd * 1000).toISOString();
  if (customerId) patch.stripe_customer_id = customerId;
  const { error } = await supabase.from("businesses").update(patch).eq("id", businessId);
  if (error) throw error;
  console.log(`Subscription for ${businessId} -> ${status}`);
}

Deno.serve(async (req) => {
  const sig = req.headers.get("stripe-signature");
  if (!sig) return new Response("Missing signature", { status: 400 });

  let event: Stripe.Event;
  try {
    const body = await req.text();
    event = await stripe.webhooks.constructEventAsync(body, sig, webhookSecret);
  } catch (err) {
    console.error("Signature verification failed:", (err as Error).message);
    return new Response(`Webhook Error: ${(err as Error).message}`, { status: 400 });
  }

  try {
    switch (event.type) {
      case "checkout.session.completed": {
        const s = event.data.object as Stripe.Checkout.Session;
        const businessId = s.client_reference_id || s.metadata?.business_id;
        if (!businessId) { console.warn("No business id on session", s.id); break; }

        if (s.mode === "payment" && s.payment_status === "paid") {
          const credits = parseInt(s.metadata?.credits ?? "0", 10);
          if (credits > 0) await grantCredits(businessId, credits, s.id);
          if (s.customer) {
            await supabase.from("businesses").update({ stripe_customer_id: s.customer as string }).eq("id", businessId);
          }
        } else if (s.mode === "subscription") {
          const sub = s.subscription
            ? await stripe.subscriptions.retrieve(s.subscription as string)
            : null;
          await setSubscription(
            businessId,
            sub?.status ?? "active",
            sub?.current_period_end ?? null,
            s.customer as string | undefined,
          );
        }
        break;
      }
      case "customer.subscription.updated":
      case "customer.subscription.deleted": {
        const sub = event.data.object as Stripe.Subscription;
        const businessId = sub.metadata?.business_id;
        if (businessId) {
          const status = event.type === "customer.subscription.deleted" ? "cancelled" : sub.status;
          await setSubscription(businessId, status, sub.current_period_end, sub.customer as string);
        }
        break;
      }
      default:
        break;
    }
  } catch (err) {
    console.error("Webhook handler error:", err);
    return new Response(`Handler error: ${(err as Error).message}`, { status: 500 });
  }

  return new Response(JSON.stringify({ received: true }), { headers: { "Content-Type": "application/json" } });
});
