-- Petoki · 005 · Share-with-vet: revocable read-only links

create table public.share_links (
  id               uuid primary key default gen_random_uuid(),
  pet_id           uuid not null references public.pets (id) on delete cascade,
  token            text not null unique default encode(extensions.gen_random_bytes(16), 'hex'),
  label            text,                       -- "drh. Sari", "Boarding kennel"
  expires_at       timestamptz default (now() + interval '30 days'),
  revoked_at       timestamptz,
  access_count     int not null default 0,
  last_accessed_at timestamptz,
  created_by       uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  created_at       timestamptz not null default now()
);

create index share_links_pet_idx on public.share_links (pet_id);

alter table public.share_links enable row level security;

create policy "share_links_all_own"
  on public.share_links for all to authenticated
  using (public.owns_pet(pet_id))
  with check (public.owns_pet(pet_id));

-- Public read-only snapshot for the vet-facing web page.
-- SECURITY DEFINER is the only door past RLS, and only through a valid,
-- unrevoked, unexpired token. Owner identity is never exposed.
create or replace function public.get_shared_pet(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  l      public.share_links%rowtype;
  result jsonb;
begin
  select * into l
  from public.share_links
  where token = p_token
    and revoked_at is null
    and (expires_at is null or expires_at > now());

  if not found then
    return null;
  end if;

  update public.share_links
  set access_count = access_count + 1, last_accessed_at = now()
  where id = l.id;

  select jsonb_build_object(
    'shared_at', now(),
    'label', l.label,
    'pet', (
      select to_jsonb(p) - 'owner_id'
      from public.pets p where p.id = l.pet_id
    ),
    'vaccines', coalesce((
      select jsonb_agg(to_jsonb(v) order by v.given_on desc nulls first)
      from public.vaccines v where v.pet_id = l.pet_id
    ), '[]'::jsonb),
    'visits', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.visited_at desc)
      from public.vet_visits x where x.pet_id = l.pet_id
    ), '[]'::jsonb),
    'medications', coalesce((
      select jsonb_agg(to_jsonb(m))
      from public.medications m
      where m.pet_id = l.pet_id and m.archived_at is null
    ), '[]'::jsonb),
    'weights', coalesce((
      select jsonb_agg(to_jsonb(w) order by w.measured_on)
      from (
        select * from public.weight_logs
        where pet_id = l.pet_id
        order by measured_on desc
        limit 30
      ) w
    ), '[]'::jsonb),
    'recent_activity', coalesce((
      select jsonb_agg(jsonb_build_object(
        'occurred_at', a.occurred_at,
        'type', t.name,
        'emoji', t.emoji,
        'duration_min', a.duration_min,
        'details', a.details,
        'note', a.note
      ) order by a.occurred_at desc)
      from public.activity_logs a
      join public.activity_types t on t.id = a.activity_type_id
      where a.pet_id = l.pet_id
        and a.occurred_at > now() - interval '7 days'
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

revoke execute on function public.get_shared_pet(text) from public;
grant execute on function public.get_shared_pet(text) to anon, authenticated;
