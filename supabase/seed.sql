-- Petoki · local-dev seed
-- Runs on `supabase db reset` (local only — never pushed to production).
--
-- Auth users can't be meaningfully seeded here, so demo data is wrapped in
-- a function: sign up once in the app (or Studio), then run
--   select public.seed_demo_data('<your-user-uuid>');

create or replace function public.seed_demo_data(p_owner uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pet uuid;
begin
  insert into public.pets (owner_id, name, species, breed, sex, birth_date)
  values (p_owner, 'Mochi', 'dog', 'Labrador mix', 'male', '2022-03-15')
  returning id into v_pet;

  insert into public.vaccines (pet_id, name, given_on, next_due_on, vet_name, clinic) values
    (v_pet, 'Rabies (annual)',   current_date - 360, current_date - 2,  'drh. Sari', 'Seminyak Vet'),
    (v_pet, 'DHPP booster',      current_date - 358, current_date + 7,  'drh. Sari', 'Seminyak Vet'),
    (v_pet, 'Bordetella',        current_date - 60,  current_date + 305, 'drh. Sari', 'Seminyak Vet'),
    (v_pet, 'Leptospirosis',     current_date - 160, current_date + 205, null,        'Bali Pet Crew');

  insert into public.appointments (pet_id, title, starts_at, vet_name, clinic)
  values (v_pet, 'Vet check-up', now() + interval '1 day', 'drh. Sari', 'Seminyak Vet');

  insert into public.vet_visits (pet_id, visited_at, reason, diagnosis, vet_name, clinic) values
    (v_pet, now() - interval '30 days', 'Annual check-up', 'Healthy', 'drh. Sari', 'Seminyak Vet'),
    (v_pet, now() - interval '90 days', 'Ear scratching', 'Mild ear infection', 'drh. Sari', 'Seminyak Vet');

  insert into public.weight_logs (pet_id, weight_kg, measured_on)
  select v_pet, 21 + (g * 0.25), current_date - ((4 - g) * 30)
  from generate_series(0, 4) g;

  -- A day of behavior logs using the built-in types
  insert into public.activity_logs (pet_id, activity_type_id, occurred_at, duration_min, details) values
    (v_pet, 'a0000000-0000-4000-a000-000000000001', date_trunc('day', now()) + interval '6 hours 10 min', 560, '{}'),
    (v_pet, 'a0000000-0000-4000-a000-000000000004', date_trunc('day', now()) + interval '6 hours 25 min', null, '{}'),
    (v_pet, 'a0000000-0000-4000-a000-000000000005', date_trunc('day', now()) + interval '6 hours 25 min', null, '{"stool":"normal"}'),
    (v_pet, 'a0000000-0000-4000-a000-000000000002', date_trunc('day', now()) + interval '6 hours 40 min', null, '{"amount_g":250,"finished":true}'),
    (v_pet, 'a0000000-0000-4000-a000-000000000006', date_trunc('day', now()) + interval '7 hours 15 min', 28, '{}');
end;
$$;

revoke execute on function public.seed_demo_data(uuid) from public, anon, authenticated;
