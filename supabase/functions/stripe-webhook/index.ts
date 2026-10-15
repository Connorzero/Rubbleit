// Stripe webhook: the ONLY place that grants credits or changes membership
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
  const { data: biz, error: selErr } = await supabase.from("businesses").select("credits").eq("id", businessId).single();
  if (selErr) throw selErr;
  const { error: updErr } = await supabase.from("businesses")
    .update({ credits: (biz?.credits ?? 0) + credits }).eq("id", businessId);
  if (updErr) throw updErr;
}

// Newer Stripe API versions move current_period_end onto the items
function periodEndOf(sub: Stripe.Subscription): number | null {
  const s = sub as unknown as { current_period_end?: number; items?: { data?: { current_period_end?: number }[] } };
  return s.current_period_end ?? s.items?.data?.[0]?.current_period_end ?? null;
}

const idOf = (v: string | { id: string } | null | undefined) => (typeof v === "string" ? v : v?.id ?? null);

async function businessIdFor(sub: Stripe.Subscription): Promise<string | null> {
  if (sub.metadata?.business_id) return sub.metadata.business_id;
  const { data } = await supabase.from("businesses").select("id")
    .eq("stripe_customer_id", idOf(sub.customer)).maybeSingle();
  return data?.id ?? null;
}

// Makes the membership card the customer's default so success fees can be
// charged to it off-session later.
async function rememberPaymentMethod(businessId: string, customerId: string, paymentMethodId: string | null) {
  if (!paymentMethodId) return;
  await stripe.customers.update(customerId, { invoice_settings: { default_payment_method: paymentMethodId } });
  const { error } = await supabase.from("businesses")
    .update({ default_payment_method_id: paymentMethodId }).eq("id", businessId);
  if (error) throw error;
}

async function syncSubscription(sub: Stripe.Subscription, deleted = false) {
  const businessId = await businessIdFor(sub);
  if (!businessId) { console.warn("No business for subscription", sub.id); return; }
  const customerId = idOf(sub.customer)!;
  const periodEnd = periodEndOf(sub);

  const patch: Record<string, unknown> = {
    subscription_status: deleted || sub.status === "canceled" ? "cancelled" : sub.status,
    stripe_subscription_id: sub.id,
    stripe_customer_id: customerId,
  };
  if (periodEnd) patch.subscription_current_period_end = new Date(periodEnd * 1000).toISOString();
  if (sub.trial_end) patch.trial_ends_at = new Date(sub.trial_end * 1000).toISOString();

  const { error } = await supabase.from("businesses").update(patch).eq("id", businessId);
  if (error) throw error;

  if (!deleted) await rememberPaymentMethod(businessId, customerId, idOf(sub.default_payment_method));
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
        } else if (s.mode === "subscription" && s.subscription) {
          const sub = await stripe.subscriptions.retrieve(idOf(s.subscription)!);
          if (!sub.metadata?.business_id) sub.metadata = { ...sub.metadata, business_id: businessId };
          await syncSubscription(sub);
        }
        break;
      }
      case "customer.subscription.created":
      case "customer.subscription.updated":
        await syncSubscription(event.data.object as Stripe.Subscription);
        break;
      case "customer.subscription.deleted":
        await syncSubscription(event.data.object as Stripe.Subscription, true);
        break;
      case "customer.updated": {
        // Fires when a card is changed in the billing portal
        const c = event.data.object as Stripe.Customer;
        const pm = idOf(c.invoice_settings?.default_payment_method as string | null);
        if (pm) {
          await supabase.from("businesses").update({ default_payment_method_id: pm }).eq("stripe_customer_id", c.id);
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
