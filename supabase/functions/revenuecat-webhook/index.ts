// Petoki · RevenueCat webhook → subscriptions table
//
// RevenueCat dashboard → Integrations → Webhooks:
//   URL:   https://<project-ref>.supabase.co/functions/v1/revenuecat-webhook
//   Header: Authorization: Bearer <REVENUECAT_WEBHOOK_TOKEN>
//
// Deploy with --no-verify-jwt (RevenueCat can't sign Supabase JWTs):
//   supabase functions deploy revenuecat-webhook --no-verify-jwt
//   supabase secrets set REVENUECAT_WEBHOOK_TOKEN=<random-string>

import { createClient } from "npm:@supabase/supabase-js@2";

const ACTIVE_EVENTS = new Set([
  "INITIAL_PURCHASE",
  "RENEWAL",
  "UNCANCELLATION",
  "PRODUCT_CHANGE",
  "TRANSFER",
]);

Deno.serve(async (req) => {
  const auth = req.headers.get("authorization");
  if (auth !== `Bearer ${Deno.env.get("REVENUECAT_WEBHOOK_TOKEN")}`) {
    return new Response("Unauthorized", { status: 401 });
  }

  const { event } = await req.json();
  // app_user_id must be set to the Supabase auth user id in the app:
  // Purchases.logIn(session.user.id)
  const userId = event?.app_user_id;
  if (!userId) return new Response("Missing app_user_id", { status: 400 });

  let status: string;
  if (ACTIVE_EVENTS.has(event.type)) {
    status = event.period_type === "TRIAL" ? "trialing" : "active";
  } else if (event.type === "EXPIRATION") {
    status = "expired";
  } else if (event.type === "CANCELLATION") {
    status = "canceled"; // keeps access until current_period_end
  } else if (event.type === "BILLING_ISSUE") {
    status = "past_due";
  } else {
    return new Response("ignored", { status: 200 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { error } = await supabase.from("subscriptions").upsert(
    {
      user_id: userId,
      status,
      product_id: event.product_id ?? null,
      store: event.store === "APP_STORE" ? "app_store" : "play_store",
      current_period_end: event.expiration_at_ms
        ? new Date(event.expiration_at_ms).toISOString()
        : null,
      rc_app_user_id: event.original_app_user_id ?? null,
    },
    { onConflict: "user_id" },
  );

  if (error) {
    console.error("subscriptions upsert failed", error);
    return new Response("error", { status: 500 });
  }
  return new Response("ok", { status: 200 });
});
