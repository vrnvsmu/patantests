-- ТестПатан ВГМУ: миграция 0002 (исправления безопасности)
-- Выполнять ОДИН раз в SQL Editor НОВОГО Supabase-проекта, сразу после 0001_init.sql.
-- ВНИМАНИЕ: не проверялась на живой базе (в моей среде нет Postgres). Сначала прогоните на тестовом проекте.

-- 1. ЛОГИНЫ: регистр не различается, хранятся в нижнем регистре
alter table public.profiles drop constraint if exists username_format;
alter table public.profiles add constraint username_format check (username ~ '^[a-z0-9_]{3,24}$');
-- (unique по username уже есть; так как значение всегда в нижнем регистре, Student1 и student1 совпадут)

-- 2. ПРОФИЛИ: создаются только триггером, не клиентом; менять можно лишь ник и аватар
drop policy if exists "profile insert own" on public.profiles;
revoke insert, delete on public.profiles from anon, authenticated;
revoke update on public.profiles from anon, authenticated;
grant update (nickname, avatar_url) on public.profiles to authenticated;

-- логины (username) больше не публичны: читать профиль можно свой или админу
drop policy if exists "profiles readable" on public.profiles;
create policy "profiles own or admin" on public.profiles for select
  using (id = auth.uid() or public.is_admin());
revoke select on public.profiles from anon;

-- аватар хранится как путь только в своей папке
alter table public.profiles drop constraint if exists avatar_own_path;
alter table public.profiles add constraint avatar_own_path
  check (avatar_url is null or avatar_url like 'avatars/' || id::text || '/%');

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_user text := lower(trim(new.raw_user_meta_data->>'username'));
begin
  insert into public.profiles(id, username, nickname)
  values (new.id, v_user,
          coalesce(nullif(trim(new.raw_user_meta_data->>'nickname'), ''), v_user));
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- 3. ОТВЕТЫ: пояснение уходит в закрытую таблицу (оно часто выдаёт ответ)
alter table public.question_answers add column if not exists explanation text;
update public.question_answers a set explanation = q.explanation
  from public.questions q where q.id = a.question_id and a.explanation is null;
alter table public.questions drop column if exists explanation;

-- правильный вариант обязан принадлежать тому же вопросу
alter table public.question_options drop constraint if exists options_id_question_uq;
alter table public.question_options add constraint options_id_question_uq unique (id, question_id);
create or replace function public.answer_option_check()
returns trigger language plpgsql set search_path = public as $$
begin
  if not exists (select 1 from public.question_options where id = new.correct_option_id and question_id = new.question_id) then
    raise exception 'Правильный вариант должен принадлежать этому вопросу';
  end if;
  return new;
end $$;
drop trigger if exists answer_option_check_trg on public.question_answers;
create trigger answer_option_check_trg before insert or update on public.question_answers
  for each row execute function public.answer_option_check();

-- 4. ВОПРОСЫ: block берётся из темы, updated_at, нельзя публиковать без ключа и без 2+ вариантов
create or replace function public.questions_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.topic_id is not null then
    select block into new.block from public.topics where id = new.topic_id;
  end if;
  new.updated_at := now();
  if new.is_published and tg_op = 'UPDATE' then
    if not exists (select 1 from public.question_answers where question_id = new.id)
       or (select count(*) from public.question_options where question_id = new.id) < 2 then
      raise exception 'Нельзя опубликовать вопрос без правильного ответа и минимум двух вариантов';
    end if;
  end if;
  if tg_op = 'INSERT' and new.is_published then
    raise exception 'Новый вопрос сначала сохраняется как черновик';
  end if;
  return new;
end $$;
drop trigger if exists questions_guard_trg on public.questions;
create trigger questions_guard_trg before insert or update on public.questions
  for each row execute function public.questions_guard();

-- 5. ПОПЫТКИ: серверная сессия вместо submit_attempt
drop function if exists public.submit_attempt(text, bigint, integer, jsonb);
alter table public.attempts add column if not exists status text not null default 'in_progress'
  check (status in ('in_progress','finished'));
alter table public.attempts add column if not exists finished_at timestamptz;
alter table public.attempts alter column correct_count set default 0;
alter table public.attempt_answers alter column is_correct drop not null;
alter table public.attempt_answers add column if not exists answered_at timestamptz;
create unique index if not exists attempt_answers_uq on public.attempt_answers(attempt_id, question_id);

-- клиент не читает и не пишет напрямую ни attempt_answers, ни записи attempts
revoke all on public.attempt_answers from anon, authenticated;
revoke insert, update, delete on public.attempts from anon, authenticated;

create or replace function public.start_attempt(p_mode text, p_topic_id bigint default null, p_count integer default 10)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_ids uuid[]; v_attempt uuid;
begin
  if v_user is null then raise exception 'Требуется вход'; end if;
  if p_mode not in ('macro','micro','theory','exam') then raise exception 'Неверный режим'; end if;
  p_count := least(greatest(coalesce(p_count, 10), 1), 50);
  if (select count(*) from public.attempts where user_id = v_user and created_at > now() - interval '1 hour') >= 30 then
    raise exception 'Слишком много попыток за час, попробуйте позже';
  end if;
  delete from public.attempts where user_id = v_user and status = 'in_progress' and created_at < now() - interval '1 day';

  select array_agg(id) into v_ids from (
    select q.id from public.questions q
    where q.is_published
      and ((p_mode = 'exam' and q.section = 'macro' and q.is_exam) or (p_mode <> 'exam' and q.section = p_mode))
      and (p_topic_id is null or q.topic_id = p_topic_id)
      and exists (select 1 from public.question_answers a where a.question_id = q.id)
    order by random() limit p_count) s;
  if v_ids is null then raise exception 'Нет доступных вопросов'; end if;

  insert into public.attempts(user_id, mode, topic_id, question_count)
  values (v_user, p_mode, p_topic_id, array_length(v_ids, 1)) returning id into v_attempt;
  insert into public.attempt_answers(attempt_id, question_id) select v_attempt, unnest(v_ids);

  return jsonb_build_object('attempt_id', v_attempt, 'questions', (
    select jsonb_agg(jsonb_build_object('id', q.id, 'prompt', q.prompt, 'image_path', q.image_path,
      'options', (select jsonb_agg(jsonb_build_object('id', o.id, 'text', o.option_text) order by o.sort_order)
                  from public.question_options o where o.question_id = q.id)))
    from public.questions q where q.id = any(v_ids)));
end $$;

create or replace function public.check_answer(p_attempt uuid, p_question uuid, p_option uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_mode text; v_status text; v_key uuid; v_expl text; v_ok boolean;
begin
  select mode, status into v_mode, v_status from public.attempts where id = p_attempt and user_id = v_user;
  if v_mode is null then raise exception 'Попытка не найдена'; end if;
  if v_status <> 'in_progress' then raise exception 'Попытка уже завершена'; end if;
  if not exists (select 1 from public.question_options where id = p_option and question_id = p_question) then
    raise exception 'Неверный вариант ответа';
  end if;
  select correct_option_id, explanation into v_key, v_expl from public.question_answers where question_id = p_question;
  v_ok := (v_key = p_option);
  update public.attempt_answers set chosen_option_id = p_option, is_correct = v_ok, answered_at = now()
   where attempt_id = p_attempt and question_id = p_question and answered_at is null;
  if not found then raise exception 'Вопрос не входит в попытку или уже отвечен'; end if;
  if v_mode = 'exam' then return jsonb_build_object('recorded', true); end if; -- в экзамене ответ не раскрывается
  return jsonb_build_object('recorded', true, 'is_correct', v_ok, 'correct_option_id', v_key, 'explanation', v_expl);
end $$;

create or replace function public.finish_attempt(p_attempt uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_status text; v_total integer; v_correct integer;
begin
  select status, question_count into v_status, v_total from public.attempts
   where id = p_attempt and user_id = v_user for update;
  if v_status is null then raise exception 'Попытка не найдена'; end if;
  if v_status = 'finished' then raise exception 'Попытка уже завершена'; end if;
  select count(*) filter (where is_correct) into v_correct from public.attempt_answers where attempt_id = p_attempt;
  update public.attempts set status = 'finished', finished_at = now(), correct_count = v_correct,
         duration_seconds = extract(epoch from now() - created_at)::integer where id = p_attempt;
  return jsonb_build_object('attempt_id', p_attempt, 'question_count', v_total, 'correct_count', v_correct,
                            'percent', round(v_correct * 100.0 / v_total, 2));
end $$;

create or replace function public.get_attempt_review(p_attempt uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.attempts where id = p_attempt and user_id = auth.uid() and status = 'finished') then
    raise exception 'Разбор доступен только после завершения вашей попытки';
  end if;
  return (select jsonb_agg(jsonb_build_object('question_id', q.id, 'prompt', q.prompt, 'image_path', q.image_path,
            'chosen_option_id', aa.chosen_option_id, 'is_correct', coalesce(aa.is_correct, false),
            'correct_option_id', k.correct_option_id, 'explanation', k.explanation))
          from public.attempt_answers aa join public.questions q on q.id = aa.question_id
          left join public.question_answers k on k.question_id = q.id where aa.attempt_id = p_attempt);
end $$;

revoke all on function public.start_attempt(text, bigint, integer), public.check_answer(uuid, uuid, uuid),
  public.finish_attempt(uuid), public.get_attempt_review(uuid) from public, anon;
grant execute on function public.start_attempt(text, bigint, integer), public.check_answer(uuid, uuid, uuid),
  public.finish_attempt(uuid), public.get_attempt_review(uuid) to authenticated;

-- 6. РЕЙТИНГ: только завершённые тесты из 5+ вопросов, минимум 3 таких теста, без логина
-- Правило: в рейтинг идут все режимы (макро, микро, теория, экзамен). Измените, если нужно.
drop view if exists public.leaderboard;
create view public.leaderboard as
select row_number() over (order by average_percent desc, correct_answers desc, attempts desc) as place, t.*
from (
  select p.id as user_id, p.nickname, p.avatar_url,
         count(a.id)::integer as attempts,
         round(avg(a.percent), 2) as average_percent,
         sum(a.correct_count)::bigint as correct_answers
  from public.profiles p join public.attempts a on a.user_id = p.id
  where a.status = 'finished' and a.question_count >= 5
  group by p.id, p.nickname, p.avatar_url
  having count(a.id) >= 3) t;
grant select on public.leaderboard to anon, authenticated;

-- 7. ХРАНИЛИЩЕ: удаление своей аватарки и фото вопросов админом
drop policy if exists "users delete own avatar" on storage.objects;
create policy "users delete own avatar" on storage.objects for delete to authenticated
using (bucket_id = 'testpatan-media' and (storage.foldername(name))[1] = 'avatars' and (storage.foldername(name))[2] = auth.uid()::text);
drop policy if exists "admin delete question photos" on storage.objects;
create policy "admin delete question photos" on storage.objects for delete to authenticated
using (bucket_id = 'testpatan-media' and (storage.foldername(name))[1] = 'questions' and public.is_admin());

-- ПЕРВЫЙ АДМИНИСТРАТОР (после регистрации своего аккаунта; подставьте свой логин в нижнем регистре):
-- insert into public.admins(user_id) select id from public.profiles where username = 'ваш_логин';
