-- Petoki · 007 · "Coming up" feed + reminder engine query

-- One feed for the dashboard: vaccines due, upcoming appointments,
-- scheduled doses. security_invoker so the caller's RLS applies.
create or replace view public.upcoming_events
with (security_invoker = on)
as
select
  v.id,
  v.pet_id,
  'vaccine'::text as kind,
  v.name          as title,
  v.next_due_on::timestamptz as due_at,
  v.reminder
from public.vaccines v
where v.next_due_on is not null

union all

select
  a.id,
  a.pet_id,
  'appointment',
  a.title,
  a.starts_at,
  a.reminder
from public.appointments a
where a.canceled_at is null
  and a.starts_at > now() - interval '12 hours'

union all

select
  d.id,
  m.pet_id,
  'medication_dose',
  m.name,
  d.scheduled_at,
  m.reminder
from public.medication_doses d
join public.medications m on m.id = d.medication_id
where d.status = 'scheduled'
  and m.archived_at is null;

-- Everything that should fire a push right now, deduped against
-- notification_log. Called by the send-reminders edge function with the
-- service role; not executable by clients.
create or replace function public.due_reminders()
returns table (
  user_id    uuid,
  expo_token text,
  kind       text,
  ref_id     uuid,
  title      text,
  body       text
)
language sql
stable
security definer
set search_path = ''
as $$
  with events as (
    select p.owner_id, p.name as pet_name, e.kind, e.id as ref_id, e.title, e.due_at
    from public.upcoming_events e
    join public.pets p on p.id = e.pet_id
    where e.reminder
      and p.archived_at is null
      and (
        (e.kind = 'vaccine'         and e.due_at::date <= current_date + 7)
        or (e.kind = 'appointment'    and e.due_at between now() and now() + interval '24 hours')
        or (e.kind = 'medication_dose' and e.due_at between now() and now() + interval '1 hour')
      )
  )
  select
    ev.owner_id,
    t.expo_token,
    ev.kind,
    ev.ref_id,
    case ev.kind
      when 'vaccine'         then ev.pet_name || ' · vaccine'
      when 'appointment'     then ev.pet_name || ' · appointment'
      else ev.pet_name || ' · medication'
    end,
    case ev.kind
      when 'vaccine' then
        case
          when ev.due_at::date < current_date
            then ev.title || ' is overdue — book a visit?'
          else ev.title || ' is due ' || to_char(ev.due_at, 'Mon DD')
        end
      when 'appointment' then ev.title || ' at ' || to_char(ev.due_at, 'HH12:MI AM')
      else 'Time for ' || ev.title || ' — mark as given when done'
    end
  from events ev
  join public.device_push_tokens t on t.user_id = ev.owner_id
  where not exists (
    select 1 from public.notification_log n
    where n.user_id = ev.owner_id
      and n.kind = ev.kind
      and n.ref_id = ev.ref_id
      and n.fire_date = current_date
  );
$$;

revoke execute on function public.due_reminders() from public, anon, authenticated;
grant execute on function public.due_reminders() to service_role;
