-- Petoki · 001 · Extensions, enums, helpers, profiles
-- Every table in this schema carries RLS; helpers here are shared by all
-- later migrations.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------- enums
create type public.pet_species as enum ('dog', 'cat', 'rabbit', 'bird', 'other');
create type public.pet_sex as enum ('male', 'female', 'unknown');
create type public.dose_status as enum ('scheduled', 'given', 'missed', 'skipped');
create type public.accent_color as enum ('green', 'amber', 'lilac', 'rose');
create type public.subscription_status as enum ('active', 'trialing', 'past_due', 'canceled', 'expired');

-- ---------------------------------------------------------------- updated_at
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------- profiles
-- One row per auth user, created automatically on signup.
create table public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  avatar_url   text,
  locale       text not null default 'en',
  timezone     text not null default 'Asia/Jakarta',
  -- Denormalized from subscriptions (kept in sync by trigger) so RLS
  -- policies and plan-limit checks never need a join.
  is_pro       boolean not null default false,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "profiles_select_own"
  on public.profiles for select to authenticated
  using ((select auth.uid()) = id);

create policy "profiles_update_own"
  on public.profiles for update to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

create trigger trg_profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- Auto-provision a profile on signup. SECURITY DEFINER so it can insert
-- regardless of RLS; no insert policy is exposed to clients.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name, avatar_url)
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data ->> 'full_name',
      new.raw_user_meta_data ->> 'name',
      split_part(new.email, '@', 1)
    ),
    new.raw_user_meta_data ->> 'avatar_url'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
