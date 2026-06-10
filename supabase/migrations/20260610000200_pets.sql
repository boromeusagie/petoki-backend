-- Petoki · 002 · Pets + ownership helper + free-plan limit

create table public.pets (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 60),
  species     public.pet_species not null,
  breed       text,
  sex         public.pet_sex not null default 'unknown',
  birth_date  date check (birth_date <= current_date),
  photo_path  text,            -- object path inside the pet-media bucket
  archived_at timestamptz,     -- soft delete: history stays, pet hides
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index pets_owner_idx on public.pets (owner_id) where archived_at is null;

alter table public.pets enable row level security;

create policy "pets_select_own"
  on public.pets for select to authenticated
  using ((select auth.uid()) = owner_id);

create policy "pets_insert_own"
  on public.pets for insert to authenticated
  with check ((select auth.uid()) = owner_id);

create policy "pets_update_own"
  on public.pets for update to authenticated
  using ((select auth.uid()) = owner_id)
  with check ((select auth.uid()) = owner_id);

create policy "pets_delete_own"
  on public.pets for delete to authenticated
  using ((select auth.uid()) = owner_id);

create trigger trg_pets_updated_at
  before update on public.pets
  for each row execute function public.set_updated_at();

-- Shared ownership check used by every child-table policy.
-- SECURITY DEFINER avoids re-evaluating pets RLS on each child row.
create or replace function public.owns_pet(p_pet_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.pets
    where id = p_pet_id
      and owner_id = (select auth.uid())
  );
$$;

revoke execute on function public.owns_pet(uuid) from public, anon;
grant execute on function public.owns_pet(uuid) to authenticated;

-- Free plan: 2 active pets. Pro: unlimited.
-- Single place to tune the limit; surface the FREE_PLAN_PET_LIMIT error
-- code in the app as the contextual paywall.
create or replace function public.enforce_pet_limit()
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
  from public.pets
  where owner_id = new.owner_id and archived_at is null;

  if v_count >= v_free_limit then
    raise exception 'FREE_PLAN_PET_LIMIT'
      using hint = 'Upgrade to Petoki Pro for unlimited pets.';
  end if;
  return new;
end;
$$;

create trigger trg_pets_plan_limit
  before insert on public.pets
  for each row execute function public.enforce_pet_limit();
