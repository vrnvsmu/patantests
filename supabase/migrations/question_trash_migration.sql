-- Корзина вопросов TestPatan
-- Выполнить один раз в Supabase SQL Editor.
create table if not exists public.question_trash (
  id uuid primary key default gen_random_uuid(),
  question_id text not null,
  question_data jsonb not null,
  options_data jsonb not null default '[]'::jsonb,
  answer_data jsonb,
  deleted_at timestamptz not null default now(),
  deleted_by uuid
);
alter table public.question_trash enable row level security;
drop policy if exists "Admins can read question trash" on public.question_trash;
create policy "Admins can read question trash" on public.question_trash for select to authenticated
using (exists (select 1 from public.admins a where a.user_id = auth.uid()));
drop policy if exists "Admins can insert question trash" on public.question_trash;
create policy "Admins can insert question trash" on public.question_trash for insert to authenticated
with check (exists (select 1 from public.admins a where a.user_id = auth.uid()));
drop policy if exists "Admins can delete question trash" on public.question_trash;
create policy "Admins can delete question trash" on public.question_trash for delete to authenticated
using (exists (select 1 from public.admins a where a.user_id = auth.uid()));
grant select, insert, delete on public.question_trash to authenticated;
