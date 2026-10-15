// Charges the success fee for an accepted quote. Account credit is always used
// first; only the remainder is charged to the business's saved card.
//
// Callers:
//   - Server code (service-role key) right after a customer accepts: { quoteId }
//   - An admin retrying a failed fee from the dashboard:              { feeId }
import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { apiVersion: "2024-06-20" });
const supabase = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey);

async function callerIsAllowed(token: string): Promise<boolean> {
  if (token === serviceKey) return true;
  const { data: { user } } = await supabase.auth.getUser(token);
  if (!user) return false;
  const { data } = await supabase.from("businesses").select("is_admin").eq("id", user.id).maybeSingle();
  return data?.is_admin === true;
}

async function markFee(feeId: string, businessId: string, patch: Record<string, unknown>, unpaid: boolean) {
  await supabase.from("success_fees").update({ ...patch, updated_at: new Date().toISOString() }).eq("id", feeId);
  await supabase.from("businesses").update({ has_unpaid_fee: unpaid }).eq("id", businessId);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  try {
    const token = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
    if (!token || !(await callerIsAllowed(token))) return json({ error: "forbidden" }, 403);

    const { quoteId, feeId: inputFeeId } = await req.json();

    let feeId = inputFeeId as string | undefined;
    if (!feeId && quoteId) {
      const { data, error } = await supabase.rpc("create_success_fee", { p_quote_id: quoteId });
      if (error) return json({ error: error.message }, 400);
      feeId = data as string;
    }
    if (!feeId) return json({ error: "quoteId_or_feeId_required" }, 400);

    const { data: fee } = await supabase.from("success_fees")
      .select("id, business_id, amount_pence, credit_applied_pence, status")
      .eq("id", feeId).single();
    if (!fee) return json({ error: "fee_not_found" }, 404);
    if (fee.status === "paid") return json({ status: "paid", alreadyPaid: true });

    // A failed fee goes back to pending so a retry can use any credit issued since.
    if (fee.status === "failed") {
      await supabase.from("success_fees").update({ status: "pending", failure_reason: null }).eq("id", feeId);
    }

    const { data: remaining, error: creditErr } = await supabase.rpc("apply_fee_credit", { p_fee_id: feeId });
    if (creditErr) return json({ error: creditErr.message }, 500);
    const toCharge = Number(remaining ?? 0);
    const creditUsed = fee.amount_pence - toCharge;

    if (toCharge <= 0) {
      await markFee(feeId, fee.business_id, { status: "paid" }, false);
      return json({ status: "paid", chargedPence: 0, creditUsedPence: creditUsed });
    }

    const { data: biz } = await supabase.from("businesses")
      .select("stripe_customer_id, default_payment_method_id")
      .eq("id", fee.business_id).single();
    if (!biz?.stripe_customer_id || !biz?.default_payment_method_id) {
      await markFee(feeId, fee.business_id, { status: "failed", failure_reason: "no_saved_card" }, true);
      return json({ status: "failed", reason: "no_saved_card" }, 402);
    }

    try {
      // Keyed on the amount too, so a retry after new credit creates a fresh charge.
      const intent = await stripe.paymentIntents.create(
        {
          amount: toCharge,
          currency: "gbp",
          customer: biz.stripe_customer_id,
          payment_method: biz.default_payment_method_id,
          off_session: true,
          confirm: true,
          description: "Rubble success fee",
          metadata: { success_fee_id: feeId, business_id: fee.business_id, credit_used_pence: String(creditUsed) },
        },
        { idempotencyKey: `success-fee-${feeId}-${toCharge}` },
      );

      if (intent.status === "succeeded") {
        await markFee(feeId, fee.business_id, { status: "paid", stripe_payment_intent_id: intent.id }, false);
        return json({ status: "paid", chargedPence: toCharge, creditUsedPence: creditUsed });
      }
      await markFee(feeId, fee.business_id,
        { status: "failed", stripe_payment_intent_id: intent.id, failure_reason: intent.status }, true);
      return json({ status: "failed", reason: intent.status }, 402);
    } catch (err) {
      const e = err as Stripe.errors.StripeError;
      await markFee(feeId, fee.business_id,
        { status: "failed", failure_reason: e.code ?? e.message ?? "charge_failed" }, true);
      return json({ status: "failed", reason: e.code ?? e.message }, 402);
    }
  } catch (err) {
    console.error("charge-success-fee error:", err);
    return json({ error: (err as Error).message }, 500);
  }
});
