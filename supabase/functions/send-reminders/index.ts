// Petoki · reminder push sender
//
// Run on a schedule (every 15 min). Two options:
//   1. Dashboard → Edge Functions → Schedules (simplest)
//   2. pg_cron + pg_net — see README "Scheduling reminders"
//
// Queries public.due_reminders() (already deduped against
// notification_log), sends via Expo Push, then records the sends.

import { createClient } from "npm:@supabase/supabase-js@2";

type Reminder = {
  user_id: string;
  expo_token: string;
  kind: string;
  ref_id: string;
  title: string;
  body: string;
};

Deno.serve(async (_req) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data, error } = await supabase.rpc("due_reminders");
  if (error) {
    console.error("due_reminders failed", error);
    return new Response("error", { status: 500 });
  }

  const reminders = (data ?? []) as Reminder[];
  if (reminders.length === 0) {
    return Response.json({ sent: 0 });
  }

  // Expo accepts up to 100 messages per request.
  let sent = 0;
  for (let i = 0; i < reminders.length; i += 100) {
    const chunk = reminders.slice(i, i + 100);
    const res = await fetch("https://exp.host/--/api/v2/push/send", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(
        chunk.map((r) => ({
          to: r.expo_token,
          title: r.title,
          body: r.body,
          sound: "default",
          data: { kind: r.kind, ref_id: r.ref_id },
        })),
      ),
    });

    if (!res.ok) {
      console.error("expo push failed", await res.text());
      continue;
    }

    // Record sends so the same reminder never fires twice in a day.
    // Deduped per (user, kind, ref) — one row even with multiple devices.
    const seen = new Set<string>();
    const rows = chunk
      .filter((r) => {
        const key = `${r.user_id}:${r.kind}:${r.ref_id}`;
        if (seen.has(key)) return false;
        seen.add(key);
        return true;
      })
      .map((r) => ({ user_id: r.user_id, kind: r.kind, ref_id: r.ref_id }));

    const { error: logError } = await supabase
      .from("notification_log")
      .upsert(rows, {
        onConflict: "user_id,kind,ref_id,fire_date",
        ignoreDuplicates: true,
      });
    if (logError) console.error("notification_log insert failed", logError);

    sent += chunk.length;
  }

  return Response.json({ sent });
});
