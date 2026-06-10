-- Petoki · 003 · Vaccines, appointments, vet visits, medications, weight

-- ---------------------------------------------------------------- vaccines
create table public.vaccines (
  id              uuid primary key default gen_random_uuid(),
  pet_id          uuid not null references public.pets (id) on delete cascade,
  name            text not null check (char_length(name) between 1 and 80),
  given_on        date,
  next_due_on     date,
  vet_name        text,
  clinic          text,
  lot_number      text,
  note            text,
  attachment_path text,                       -- certificate photo/PDF in pet-media
  reminder        boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (given_on is not null or next_due_on is not null)
);

create index vaccines_pet_due_idx on public.vaccines (pet_id, next_due_on);

-- ---------------------------------------------------------------- appointments
-- Future bookings ("Vet check-up tomorrow 4 PM"). Past care is vet_visits.
create table public.appointments (
  id          uuid primary key default gen_random_uuid(),
  pet_id      uuid not null references public.pets (id) on delete cascade,
  title       text not null default 'Vet appointment',
  starts_at   timestamptz not null,
  vet_name    text,
  clinic      text,
  location    text,
  note        text,
  reminder    boolean not null default true,
  canceled_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index appointments_pet_time_idx on public.appointments (pet_id, starts_at);

-- ---------------------------------------------------------------- vet_visits
create table public.vet_visits (
  id              uuid primary key default gen_random_uuid(),
  pet_id          uuid not null references public.pets (id) on delete cascade,
  visited_at      timestamptz not null,
  reason          text not null,
  diagnosis       text,
  treatment       text,
  vet_name        text,
  clinic          text,
  cost            numeric(12, 2) check (cost >= 0),
  note            text,
  attachment_path text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index vet_visits_pet_time_idx on public.vet_visits (pet_id, visited_at desc);

-- ---------------------------------------------------------------- medications
create table public.medications (
  id           uuid primary key default gen_random_uuid(),
  pet_id       uuid not null references public.pets (id) on delete cascade,
  name         text not null check (char_length(name) between 1 and 80),
  dosage       text,                          -- "5 mg", "1/2 tablet"
  instructions text,                          -- "with food"
  dose_times   time[] not null default '{08:00}',  -- local times, see README
  start_on     date not null default current_date,
  end_on       date check (end_on >= start_on),
  reminder     boolean not null default true,
  archived_at  timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index medications_pet_idx on public.medications (pet_id) where archived_at is null;

-- One row per scheduled dose; drives the compliance grid and reminders.
create table public.medication_doses (
  id            uuid primary key default gen_random_uuid(),
  medication_id uuid not null references public.medications (id) on delete cascade,
  scheduled_at  timestamptz not null,
  status        public.dose_status not null default 'scheduled',
  logged_at     timestamptz,
  unique (medication_id, scheduled_at)
);

create index medication_doses_sched_idx on public.medication_doses (medication_id, scheduled_at);

-- ---------------------------------------------------------------- weight_logs
create table public.weight_logs (
  id          uuid primary key default gen_random_uuid(),
  pet_id      uuid not null references public.pets (id) on delete cascade,
  weight_kg   numeric(6, 2) not null check (weight_kg > 0 and weight_kg < 500),
  measured_on date not null default current_date,
  note        text,
  created_at  timestamptz not null default now()
);

create index weight_logs_pet_date_idx on public.weight_logs (pet_id, measured_on desc);

-- ---------------------------------------------------------------- RLS
-- Identical owner-through-pet policies for every health table.
alter table public.vaccines enable row level security;
alter table public.appointments enable row level security;
alter table public.vet_visits enable row level security;
alter table public.medications enable row level security;
alter table public.medication_doses enable row level security;
alter table public.weight_logs enable row level security;

create policy "vaccines_all_own" on public.vaccines
  for all to authenticated
  using (public.owns_pet(pet_id)) with check (public.owns_pet(pet_id));

create policy "appointments_all_own" on public.appointments
  for all to authenticated
  using (public.owns_pet(pet_id)) with check (public.owns_pet(pet_id));

create policy "vet_visits_all_own" on public.vet_visits
  for all to authenticated
  using (public.owns_pet(pet_id)) with check (public.owns_pet(pet_id));

create policy "medications_all_own" on public.medications
  for all to authenticated
  using (public.owns_pet(pet_id)) with check (public.owns_pet(pet_id));

create policy "medication_doses_all_own" on public.medication_doses
  for all to authenticated
  using (exists (
    select 1 from public.medications m
    where m.id = medication_id and public.owns_pet(m.pet_id)
  ))
  with check (exists (
    select 1 from public.medications m
    where m.id = medication_id and public.owns_pet(m.pet_id)
  ));

create policy "weight_logs_all_own" on public.weight_logs
  for all to authenticated
  using (public.owns_pet(pet_id)) with check (public.owns_pet(pet_id));

create trigger trg_vaccines_updated_at
  before update on public.vaccines
  for each row execute function public.set_updated_at();
create trigger trg_appointments_updated_at
  before update on public.appointments
  for each row execute function public.set_updated_at();
create trigger trg_vet_visits_updated_at
  before update on public.vet_visits
  for each row execute function public.set_updated_at();
create trigger trg_medications_updated_at
  before update on public.medications
  for each row execute function public.set_updated_at();

-- Idempotently materialize scheduled doses out to a horizon.
-- Runs as the caller, so RLS guarantees they own the medication.
create or replace function public.generate_medication_doses(
  p_medication_id uuid,
  p_until date default (current_date + 14)
)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  m       public.medications%rowtype;
  d       date;
  t       time;
  created int := 0;
begin
  select * into m from public.medications where id = p_medication_id;
  if not found then
    raise exception 'medication not found';
  end if;

  d := greatest(m.start_on, current_date);
  while d <= least(coalesce(m.end_on, p_until), p_until) loop
    foreach t in array m.dose_times loop
      insert into public.medication_doses (medication_id, scheduled_at)
      values (p_medication_id, (d + t)::timestamptz)
      on conflict (medication_id, scheduled_at) do nothing;
      if found then
        created := created + 1;
      end if;
    end loop;
    d := d + 1;
  end loop;

  return created;
end;
$$;
