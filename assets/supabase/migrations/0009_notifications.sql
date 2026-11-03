-- 0009_notifications.sql
-- Рассылка уведомлений: администратор создаёт, все посетители видят в колокольчике.
begin;
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 120),
  body text check (body is null or char_length(body) <= 2000),
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null default auth.uid()
);
create index if not exists notifications_created_idx on public.notifications(created_at desc);
alter table public.notifications enable row level security;

drop policy if exists "notifications readable by all" on public.notifications;
create policy "notifications readable by all" on public.notifications for select to anon, authenticated using (true);
drop policy if exists "admin manage notifications" on public.notifications;
create policy "admin manage notifications" on public.notifications for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

grant select on public.notifications to anon, authenticated;
grant insert, delete on public.notifications to authenticated;
commit;
