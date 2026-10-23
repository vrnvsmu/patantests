-- 0005_guest_test_solving.sql
-- Разрешаем гостевые попытки без аккаунта. Гостевые попытки не привязываются к профилю
-- и не попадают в личную статистику/рейтинг. Доступ к конкретной попытке осуществляется
-- по непредсказуемому UUID, который генерирует PostgreSQL.
begin;

alter table public.attempts alter column user_id drop not null;

create or replace function public.start_attempt(p_mode text, p_topic_id bigint default null, p_count integer default 10)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_ids uuid[]; v_attempt uuid;
begin
  if p_mode not in ('macro','micro','theory','exam') then raise exception 'Неверный режим'; end if;
  p_count := least(greatest(coalesce(p_count, 10), 1), 50);

  if v_user is not null then
    if (select count(*) from public.attempts where user_id = v_user and created_at > now() - interval '1 hour') >= 30 then
      raise exception 'Слишком много попыток за час, попробуйте позже';
    end if;
    delete from public.attempts where user_id = v_user and status = 'in_progress' and created_at < now() - interval '1 day';
  else
    -- Удаляем только устаревшие незавершённые гостевые сессии.
    delete from public.attempts where user_id is null and status = 'in_progress' and created_at < now() - interval '1 day';
  end if;

  select array_agg(id) into v_ids from (
    select q.id from public.questions q
    where q.is_published
      and ((p_mode = 'exam' and q.section = 'macro' and q.is_exam) or (p_mode <> 'exam' and q.section = p_mode))
      and (p_topic_id is null or q.topic_id = p_topic_id)
      and exists (select 1 from public.question_answers a where a.question_id = q.id)
    order by random() limit p_count
  ) s;
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
  select mode, status into v_mode, v_status from public.attempts
   where id = p_attempt and ((v_user is not null and user_id = v_user) or (v_user is null and user_id is null));
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
  if v_mode = 'exam' then return jsonb_build_object('recorded', true); end if;
  return jsonb_build_object('recorded', true, 'is_correct', v_ok, 'correct_option_id', v_key, 'explanation', v_expl);
end $$;

create or replace function public.finish_attempt(p_attempt uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_status text; v_total integer; v_correct integer;
begin
  select status, question_count into v_status, v_total from public.attempts
   where id = p_attempt and ((v_user is not null and user_id = v_user) or (v_user is null and user_id is null)) for update;
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
declare v_user uuid := auth.uid();
begin
  if not exists (select 1 from public.attempts where id = p_attempt
    and ((v_user is not null and user_id = v_user) or (v_user is null and user_id is null)) and status = 'finished') then
    raise exception 'Разбор доступен только после завершения вашей попытки';
  end if;
  return (select jsonb_agg(jsonb_build_object('question_id', q.id, 'prompt', q.prompt, 'image_path', q.image_path,
            'chosen_option_id', aa.chosen_option_id, 'is_correct', coalesce(aa.is_correct, false),
            'correct_option_id', k.correct_option_id, 'explanation', k.explanation))
          from public.attempt_answers aa join public.questions q on q.id = aa.question_id
          left join public.question_answers k on k.question_id = q.id where aa.attempt_id = p_attempt);
end $$;

revoke all on function public.start_attempt(text, bigint, integer) from public;
revoke all on function public.check_answer(uuid, uuid, uuid) from public;
revoke all on function public.finish_attempt(uuid) from public;
revoke all on function public.get_attempt_review(uuid) from public;
grant execute on function public.start_attempt(text, bigint, integer) to anon, authenticated;
grant execute on function public.check_answer(uuid, uuid, uuid) to anon, authenticated;
grant execute on function public.finish_attempt(uuid) to anon, authenticated;
grant execute on function public.get_attempt_review(uuid) to anon, authenticated;

commit;
