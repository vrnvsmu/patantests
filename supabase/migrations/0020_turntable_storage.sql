-- 0020_turntable_storage.sql
-- Хранилище 360° наборов, создаваемых из админки сайта.
begin;

create table if not exists public.turntable_sets (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  frame_paths jsonb not null default '[]'::jsonb,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint turntable_frames_array check (jsonb_typeof(frame_paths) = 'array')
);

alter table public.turntable_sets enable row level security;

drop policy if exists "published turntables readable" on public.turntable_sets;
create policy "published turntables readable" on public.turntable_sets
  for select using (true);

drop policy if exists "admin manage turntables" on public.turntable_sets;
create policy "admin manage turntables" on public.turntable_sets
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

grant select on public.turntable_sets to anon, authenticated;
grant insert, update, delete on public.turntable_sets to authenticated;

drop policy if exists "admin upload turntable frames" on storage.objects;
create policy "admin upload turntable frames" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'testpatan-media'
    and (storage.foldername(name))[1] = 'turntables'
    and public.is_admin()
  );

drop policy if exists "admin update turntable frames" on storage.objects;
create policy "admin update turntable frames" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'testpatan-media'
    and (storage.foldername(name))[1] = 'turntables'
    and public.is_admin()
  )
  with check (
    bucket_id = 'testpatan-media'
    and (storage.foldername(name))[1] = 'turntables'
    and public.is_admin()
  );

drop policy if exists "admin delete turntable frames" on storage.objects;
create policy "admin delete turntable frames" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'testpatan-media'
    and (storage.foldername(name))[1] = 'turntables'
    and public.is_admin()
  );

commit;
