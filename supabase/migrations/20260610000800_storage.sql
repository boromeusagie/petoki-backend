-- Petoki · 008 · Storage: private pet-media bucket (photos + documents)
-- Object paths are namespaced by user: {user_id}/{pet_id}/{filename}
-- The app reads via short-lived signed URLs.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'pet-media',
  'pet-media',
  false,
  10485760, -- 10 MB
  array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf']
)
on conflict (id) do nothing;

create policy "pet_media_select_own"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'pet-media'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "pet_media_insert_own"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'pet-media'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "pet_media_update_own"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'pet-media'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "pet_media_delete_own"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'pet-media'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
