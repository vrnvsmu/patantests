-- 0010_grouped_questions.sql
-- Вопросы с одним и тем же фото считаются ОДНИМ заданием и попадают в тест вместе.
-- start_attempt выбирает случайные «задания» (фото целиком), а не отдельные вопросы;
-- в попытку берутся все вопросы выбранного фото, поэтому вопросов может быть чуть больше p_count.
-- Вопросы без фото по-прежнему выбираются по одному.
begin;

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
    delete from public.attempts where user_id is null and status = 'in_progress' and created_at < now() - interval '1 day';
  end if;

  with cand as (
    select q.id, coalesce(q.image_path, q.id::text) as gk
    from public.questions q
    where q.is_published
      and ((p_mode = 'exam' and q.section = 'macro' and q.is_exam) or (p_mode <> 'exam' and q.section = p_mode))
      and (p_topic_id is null or q.topic_id = p_topic_id)
      and exists (select 1 from public.question_answers a where a.question_id = q.id)
  ), grp as (
    select gk, count(*) as n, random() as r from cand group by gk
  ), cum as (
    select gk, n, sum(n) over (order by r) as cs from grp
  )
  select array_agg(c.id) into v_ids
  from cand c where c.gk in (select gk from cum where cs - n < p_count);
  if v_ids is null then raise exception 'Нет доступных вопросов'; end if;

  insert into public.attempts(user_id, mode, topic_id, question_count)
  values (v_user, p_mode, p_topic_id, array_length(v_ids, 1)) returning id into v_attempt;
  insert into public.attempt_answers(attempt_id, question_id) select v_attempt, unnest(v_ids);

  return jsonb_build_object('attempt_id', v_attempt, 'questions', (
    select jsonb_agg(jsonb_build_object('id', q.id, 'prompt', q.prompt, 'image_path', q.image_path, 'created_at', q.created_at,
      'options', (select jsonb_agg(jsonb_build_object('id', o.id, 'text', o.option_text) order by o.sort_order)
                  from public.question_options o where o.question_id = q.id))
      order by q.image_path nulls last, q.created_at)
    from public.questions q where q.id = any(v_ids)));
end $$;

-- то же поле created_at для теста по избранному (чтобы вопросы одного фото шли по порядку)
create or replace function public.start_favorites_attempt(p_count integer default 20)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_ids uuid[]; v_attempt uuid;
begin
  if v_user is null then raise exception 'Войдите, чтобы решать избранные вопросы'; end if;
  p_count := least(greatest(coalesce(p_count, 20), 1), 50);
  if (select count(*) from public.attempts where user_id = v_user and created_at > now() - interval '1 hour') >= 30 then
    raise exception 'Слишком много попыток за час, попробуйте позже';
  end if;
  delete from public.attempts where user_id = v_user and status = 'in_progress' and created_at < now() - interval '1 day';
  select array_agg(id) into v_ids from (
    select q.id from public.question_favorites f
    join public.questions q on q.id = f.question_id
    where f.user_id = v_user and q.is_published
      and exists (select 1 from public.question_answers a where a.question_id = q.id)
    order by random() limit p_count
  ) s;
  if v_ids is null then raise exception 'В избранном нет доступных вопросов'; end if;
  insert into public.attempts(user_id, mode, topic_id, question_count)
  values (v_user, 'favorites', null, array_length(v_ids, 1)) returning id into v_attempt;
  insert into public.attempt_answers(attempt_id, question_id) select v_attempt, unnest(v_ids);
  return jsonb_build_object('attempt_id', v_attempt, 'questions', (
    select jsonb_agg(jsonb_build_object('id', q.id, 'prompt', q.prompt, 'image_path', q.image_path, 'created_at', q.created_at,
      'options', (select jsonb_agg(jsonb_build_object('id', o.id, 'text', o.option_text) order by o.sort_order)
                  from public.question_options o where o.question_id = q.id))
      order by q.image_path nulls last, q.created_at)
    from public.questions q where q.id = any(v_ids)));
end $$;

revoke all on function public.start_attempt(text, bigint, integer) from public;
grant execute on function public.start_attempt(text, bigint, integer) to anon, authenticated;
revoke all on function public.start_favorites_attempt(integer) from public, anon;
grant execute on function public.start_favorites_attempt(integer) to authenticated;
commit;
