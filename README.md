# Petoki Backend (Supabase)

Complete database schema, RLS policies, storage, and edge functions for the
Petoki pet-health app. Pairs with the Expo app in `../petoki-frontend`.

Linked project: **Petoki** (`jsmcaskkwzircdoaeryn`, ap-southeast-1).

## Schema at a glance

| Table | Purpose |
|---|---|
| `profiles` | One per auth user, auto-created on signup. Holds `is_pro` (synced from subscriptions). |
| `pets` | Pets with soft-delete (`archived_at`). Free plan: 2 active pets (trigger-enforced). |
| `vaccines` | Given / next-due dates drive status (done / due soon / overdue) in the app. |
| `appointments` | Future bookings ("vet check-up tomorrow 4 PM"). |
| `vet_visits` | Past care history for the health timeline. |
| `medications` + `medication_doses` | Dose schedule materialized by `generate_medication_doses()`; doses drive the compliance grid and pushes. |
| `weight_logs` | Weight trend chart. |
| `activity_types` | Behavior-log types. Built-ins have `owner_id IS NULL` (fixed UUIDs `a0000000-…-01…07`); custom types are user rows. Free plan: 2 custom types. |
| `activity_logs` | The daily behavior log (highest write volume). `details` jsonb for per-type extras. |
| `share_links` | Revocable, expiring read-only tokens for the share-with-vet flow. |
| `subscriptions` | Written only by the RevenueCat webhook (service role). |
| `device_push_tokens` | Expo push tokens per device. |
| `notification_log` | Dedupe: one push per (user, kind, record, day). |

Plus: `upcoming_events` view (the dashboard "Coming up" feed),
`daily_activity_summary(pet, day)` (totals strip),
`get_shared_pet(token)` (anon-callable vet snapshot),
`due_reminders()` (service-role-only push queue),
private `pet-media` storage bucket (paths: `{user_id}/{pet_id}/{file}`).

## Security model

- RLS enabled on every table; all access is owner-scoped via `owns_pet()`.
- `subscriptions` and `notification_log` have no write policies — service
  role only.
- The **only** unauthenticated door is `get_shared_pet(token)`, gated by an
  unrevoked, unexpired 128-bit token, and it never exposes the owner.
- Plan limits raise `FREE_PLAN_PET_LIMIT` / `FREE_PLAN_ACTIVITY_LIMIT` —
  catch these error messages in the app to show the contextual paywall.

## Deploy

```bash
cd petoki-backend
supabase login
supabase link --project-ref jsmcaskkwzircdoaeryn
supabase db push                      # applies migrations in order

supabase functions deploy revenuecat-webhook --no-verify-jwt
supabase functions deploy send-reminders
supabase secrets set REVENUECAT_WEBHOOK_TOKEN=<long-random-string>
```

Local development instead: `supabase start && supabase db reset`.

## Scheduling reminders

Easiest: Dashboard → Edge Functions → `send-reminders` → Schedules → every
15 minutes. Or with pg_cron + pg_net (run once in the SQL editor):

```sql
select cron.schedule(
  'petoki-send-reminders', '*/15 * * * *',
  $$ select net.http_post(
       url := 'https://jsmcaskkwzircdoaeryn.supabase.co/functions/v1/send-reminders',
       headers := jsonb_build_object('Authorization', 'Bearer ' || '<anon-or-service-key>')
     ) $$
);
```

## Conventions & decisions

- **Soft deletes** (`archived_at`) on pets, medications, activity_types —
  history is the product; never cascade it away.
- **Built-in vs custom activity types** are the same table; the app renders
  them identically. Archive customs instead of deleting (`on delete
  restrict` protects logged history).
- **`dose_times` are local clock times.** Doses are materialized at the
  server's UTC interpretation; if you later support traveling users, store
  the pet's timezone on `pets` and shift in `generate_medication_doses`.
- **`is_pro` is denormalized** onto profiles by trigger so limit checks and
  the app never join subscriptions.
- After schema changes, regenerate app types:
  `supabase gen types typescript --linked > ../petoki-frontend/src/lib/database.types.ts`

## RevenueCat wiring

In the app, after sign-in: `Purchases.logIn(session.user.id)` so RevenueCat's
`app_user_id` equals the Supabase user id — the webhook upserts by it.
