-- Petoki · 006 · Subscriptions (RevenueCat), push tokens, notification dedupe

-- Written exclusively by the revenuecat-webhook edge function via the
-- service role. Clients can only read their own row.
create table public.subscriptions (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null unique references public.profiles (id) on delete cascade,
  status             public.subscription_status not null,
  entitlement        text not null default 'pro',
  product_id         text,
  store              text check (store in ('app_store', 'play_store', 'stripe', 'promo')),
  current_period_end timestamptz,
  rc_app_user_id     text,
  updated_at         timestamptz not null default now()
);

alter table public.subscriptions enable row level security;

create policy "subscriptions_select_own"
  on public.subscriptions for select to authenticated
  using ((select auth.uid()) = user_id);
-- No insert/update/delete policies: service role only.

create trigger trg_subscriptions_updated_at
  before update on public.subscriptions
  for each row execute function public.set_updated_at();

-- Keep profiles.is_pro in sync so plan checks never join.
create or replace function public.sync_profile_pro()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.profiles
  set is_pro = (
    new.status in ('active', 'trialing')
    and (new.current_period_end is null or new.current_period_end > now())
  )
  where id = new.user_id;
  return new;
end;
$$;

create trigger trg_subscriptions_sync_pro
  after insert or update on public.subscriptions
  for each row execute function public.sync_profile_pro();

-- ---------------------------------------------------------------- push tokens
create table public.device_push_tokens (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  expo_token   text not null unique,           -- ExponentPushToken[...]
  platform     text not null check (platform in ('ios', 'android')),
  last_seen_at timestamptz not null default now()
);

create index device_push_tokens_user_idx on public.device_push_tokens (user_id);

alter table public.device_push_tokens enable row level security;

create policy "device_push_tokens_all_own"
  on public.device_push_tokens for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

-- ---------------------------------------------------------------- dedupe log
-- One reminder per (user, kind, record, day) - the send-reminders edge
-- function checks this before pushing. Service role only.
create table public.notification_log (
  id        uuid primary key default gen_random_uuid(),
  user_id   uuid not null references public.profiles (id) on delete cascade,
  kind      text not null,
  ref_id    uuid not null,
  fire_date date not null default current_date,
  sent_at   timestamptz not null default now(),
  unique (user_id, kind, ref_id, fire_date)
);

alter table public.notification_log enable row level security;
-- No policies: invisible to clients by design.
