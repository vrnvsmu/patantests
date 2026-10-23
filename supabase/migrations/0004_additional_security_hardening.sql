-- 0004_additional_security_hardening.sql
-- Дополнительное усиление для уже установленного проекта.
-- Сначала сделайте резервную копию и проверьте на тестовом проекте.
begin;

-- Убираем любые прямые права клиента на таблицу администраторов.
-- Назначение администратора выполняется только владельцем проекта через SQL Editor.
alter table public.admins enable row level security;
revoke all on table public.admins from anon, authenticated;
grant select on table public.admins to authenticated;
drop policy if exists "admins self not readable" on public.admins;
create policy "admins self not readable" on public.admins
  for select to authenticated using (user_id = auth.uid());

-- Никакой анонимный клиент не должен читать профили.
revoke all on table public.profiles from anon;
grant select on table public.profiles to authenticated;
revoke insert, delete on table public.profiles from anon, authenticated;
revoke update on table public.profiles from anon, authenticated;
grant update (nickname, avatar_url) on table public.profiles to authenticated;

-- Запрет прямого доступа к журналу ответов: только серверные функции.
alter table public.attempt_answers enable row level security;
revoke all on table public.attempt_answers from anon, authenticated;
alter table public.attempts enable row level security;
revoke insert, update, delete on table public.attempts from anon, authenticated;
grant select on table public.attempts to authenticated;

-- Правильные ответы и пояснения доступны только серверным функциям/админу.
alter table public.question_answers enable row level security;
revoke all on table public.question_answers from anon, authenticated;
grant select, insert, update, delete on table public.question_answers to authenticated;

-- Ограничиваем прямые вызовы внутренних функций старого варианта.
revoke all on function public.submit_attempt(text, bigint, integer, jsonb) from public, anon, authenticated;

-- Убедимся, что новые попытки и ответы доступны только вошедшим пользователям.
revoke all on function public.start_attempt(text, bigint, integer) from public, anon;
revoke all on function public.check_answer(uuid, uuid, uuid) from public, anon;
revoke all on function public.finish_attempt(uuid) from public, anon;
revoke all on function public.get_attempt_review(uuid) from public, anon;
grant execute on function public.start_attempt(text, bigint, integer) to authenticated;
grant execute on function public.check_answer(uuid, uuid, uuid) to authenticated;
grant execute on function public.finish_attempt(uuid) to authenticated;
grant execute on function public.get_attempt_review(uuid) to authenticated;

commit;
