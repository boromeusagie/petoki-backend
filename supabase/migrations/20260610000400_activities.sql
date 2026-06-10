-- Petoki · 004 · Daily behavior log: activity types (built-in + custom) and logs

-- Built-ins are rows with owner_id IS NULL; custom types belong to a user.
-- The app treats both identically, so the timeline / totals / share PDF
-- need no special-casing.
create table public.activity_types (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid references public.profiles (id) on delete cascade,
  name         text not null check (char_length(name) between 1 and 40),
  emoji        text not null default '🐾' check (char_length(emoji) <= 8),
  color        public.accent_color not null default 'green',
  has_duration boolean not null default false,
  sort_order   int not null default 100,
  archived_at  timestamptz,   -- archive instead of delete: history stays intact
  created_at   timestamptz not null default now()
);

-- Name unique per user; NULLS NOT DISTINCT also dedupes the built-in set.
create unique index activity_types_owner_name_key
  on public.activity_types (owner_id, lower(name)) nulls not distinct;

-- Fixed UUIDs so clients and seed data can reference built-ins stably.
insert into public.activity_types (id, owner_id, name, emoji, color, has_duration, sort_order) values
  ('a0000000-0000-4000-a000-000000000001', null, 'Sleep', '😴', 'lilac', true,  10),
  ('a0000000-0000-4000-a000-000000000002', null, 'Meal',  '🍖', 'green', false, 20),
  ('a0000000-0000-4000-a000-000000000003', null, 'Water', '🚰', 'lilac', false, 30),
  ('a0000000-0000-4000-a000-000000000004', null, 'Pee',   '💧', 'amber', false, 40),
  ('a0000000-0000-4000-a000-000000000005', null, 'Poo',   '💩', 'rose',  false, 50),
  ('a0000000-0000-4000-a000-000000000006', null, 'Walk',  '🦮', 'green', true,  60),
  ('a0000000-0000-4000-a000-000000000007', null, 'Play',  '🎾', 'amber', true,  70);

alter table public.activity_types enable row level security;

create policy "activity_types_select_visible"
  on public.activity_types for select to authenticated
  using (owner_id is null or owner_id = (select auth.uid()));

create policy "activity_types_insert_own"
  on public.activity_types for insert to authenticated
  with check (owner_id = (select auth.uid()));

create policy "activity_types_update_own"
  on public.activity_types for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

create policy "activity_types_delete_own"
  on public.activity_types for delete to authenticated
  using (owner_id = (select auth.uid()));

-- Free plan: 2 custom activity types. The "New" tile becomes the
-- contextual paywall when this raises FREE_PLAN_ACTIVITY_LIMIT.
create or replace function public.enforce_activity_type_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_free_limit constant int := 2;
  v_is_pro boolean;
  v_count  int;
begin
  select is_pro into v_is_pro from public.profiles where id = new.owner_id;
  if coalesce(v_is_pro, false) then
    return new;
  end if;

  select count(*) into v_count
  from public.activity_types
  where owner_id = new.owner_id and archived_at is null;

  if v_count >= v_free_limit then
    raise exception 'FREE_PLAN_ACTIVITY_LIMIT'
      using hint = 'Upgrade to Petoki Pro for unlimited custom activities.';
  end if;
  return new;
end;
$$;

create trigger trg_activity_types_plan_limit
  before insert on public.activity_types
  for each row execute function public.enforce_activity_type_limit();

-- ---------------------------------------------------------------- logs
-- Highest-write-volume table in the app: 10-20 events/day per pet.
create table public.activity_logs (
  id               uuid primary key default gen_random_uuid(),
  pet_id           uuid not null references public.pets (id) on delete cascade,
  activity_type_id uuid not null references public.activity_types (id) on delete restrict,
  occurred_at      timestamptz not null default now(),
  duration_min     int check (duration_min between 1 and 1440),
  details          jsonb not null default '{}'::jsonb,  -- {"amount_g":250} / {"stool":"normal"}
  note             text,
  created_at       timestamptz not null default now()
);

create index activity_logs_pet_time_idx on public.activity_logs (pet_id, occurred_at desc);
create index activity_logs_type_idx on public.activity_logs (activity_type_id);

alter table public.activity_logs enable row level security;

create policy "activity_logs_select_own"
  on public.activity_logs for select to authenticated
  using (public.owns_pet(pet_id));

-- Insert requires owning the pet AND the type being visible (built-in or
-- the user's own, not archived).
create policy "activity_logs_insert_own"
  on public.activity_logs for insert to authenticated
  with check (
    public.owns_pet(pet_id)
    and exists (
      select 1 from public.activity_types t
      where t.id = activity_type_id
        and (t.owner_id is null or t.owner_id = (select auth.uid()))
        and t.archived_at is null
    )
  );

create policy "activity_logs_update_own"
  on public.activity_logs for update to authenticated
  using (public.owns_pet(pet_id))
  with check (public.owns_pet(pet_id));

create policy "activity_logs_delete_own"
  on public.activity_logs for delete to authenticated
  using (public.owns_pet(pet_id));

-- Daily totals strip ("Sleep 9h 20 · Meals 2/2 · Pee 4 · Poo 1") in one call.
create or replace function public.daily_activity_summary(p_pet_id uuid, p_day date)
returns table (
  activity_type_id uuid,
  name             text,
  emoji            text,
  event_count      bigint,
  total_minutes    bigint
)
language sql
stable
set search_path = ''
as $$
  select t.id, t.name, t.emoji,
         count(a.id),
         coalesce(sum(a.duration_min), 0)::bigint
  from public.activity_logs a
  join public.activity_types t on t.id = a.activity_type_id
  where a.pet_id = p_pet_id
    and a.occurred_at >= p_day::timestamptz
    and a.occurred_at < (p_day + 1)::timestamptz
  group by t.id, t.name, t.emoji, t.sort_order
  order by t.sort_order;
$$;
