-- TestPatan: безопасная миграция комментариев к вопросам
-- Использует существующую функцию public.is_admin(); не требует profiles.is_admin.
begin;

create table if not exists public.question_comments (
  id uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.questions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  comment text not null check (length(trim(comment)) between 1 and 3000),
  created_at timestamptz not null default now()
);

create index if not exists question_comments_created_at_idx
  on public.question_comments(created_at desc);

alter table public.question_comments enable row level security;

drop policy if exists question_comments_insert_own on public.question_comments;
create policy question_comments_insert_own
  on public.question_comments
  for insert to authenticated
  with check (auth.uid() = user_id);

drop policy if exists question_comments_select_admin on public.question_comments;
create policy question_comments_select_admin
  on public.question_comments
  for select to authenticated
  using (public.is_admin());

drop policy if exists question_comments_delete_admin on public.question_comments;
create policy question_comments_delete_admin
  on public.question_comments
  for delete to authenticated
  using (public.is_admin());

grant select, insert, delete on public.question_comments to authenticated;

commit;
