--
-- PostgreSQL database dump
--


-- Dumped from database version 17.11
-- Dumped by pg_dump version 19.0

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA IF NOT EXISTS public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: admin_question_statistics(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_question_statistics() RETURNS TABLE(mode text, topic_id bigint, topic_title text, question_id uuid, prompt text, image_path text, total_answers bigint, correct_count bigint, correct_rate numeric, option_id uuid, option_text text, is_correct boolean, selected_count bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Только для администратора';
  END IF;

  RETURN QUERY
  WITH first_ans AS (
    SELECT DISTINCT ON (
      COALESCE(a.user_id::text, a.id::text),
      aa.question_id,
      a.mode
    )
      a.mode AS f_mode,
      aa.question_id AS f_q,
      aa.chosen_option_id AS f_opt,
      COALESCE(aa.is_correct, false) AS f_ok
    FROM public.attempt_answers aa
    JOIN public.attempts a ON a.id = aa.attempt_id
    WHERE a.mode <> 'favorites'
      AND aa.chosen_option_id IS NOT NULL
    ORDER BY
      COALESCE(a.user_id::text, a.id::text),
      aa.question_id,
      a.mode,
      aa.answered_at NULLS LAST,
      a.created_at
  ),
  agg AS (
    SELECT f_mode, f_q,
           COUNT(*)::bigint AS tot,
           COUNT(*) FILTER (WHERE f_ok)::bigint AS cor
    FROM first_ans
    GROUP BY f_mode, f_q
  ),
  sel AS (
    SELECT f_mode, f_q, f_opt, COUNT(*)::bigint AS n
    FROM first_ans
    GROUP BY f_mode, f_q, f_opt
  )
  SELECT
    g.f_mode,
    q.topic_id,
    COALESCE(t.title, 'Без темы'),
    q.id,
    q.prompt,
    q.image_path,
    g.tot,
    g.cor,
    ROUND(g.cor * 100.0 / NULLIF(g.tot, 0), 1),
    o.id,
    o.option_text,
    (o.id = k.correct_option_id),
    COALESCE(s.n, 0)
  FROM agg g
  JOIN public.questions q ON q.id = g.f_q
  LEFT JOIN public.topics t ON t.id = q.topic_id
  LEFT JOIN public.question_answers k ON k.question_id = q.id
  JOIN public.question_options o ON o.question_id = q.id
  LEFT JOIN sel s
    ON s.f_mode = g.f_mode
   AND s.f_q = g.f_q
   AND s.f_opt = o.id
  ORDER BY g.f_mode, q.topic_id, q.id, o.sort_order;
END;
$$;


--
-- Name: answer_option_check(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.answer_option_check() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  if not exists (select 1 from public.question_options where id = new.correct_option_id and question_id = new.question_id) then
    raise exception 'Правильный вариант должен принадлежать этому вопросу';
  end if;
  return new;
end $$;


--
-- Name: check_answer(uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_answer(p_attempt uuid, p_question uuid, p_option uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_user uuid := auth.uid();
  v_mode text;
  v_status text;
  v_key uuid;
  v_expl text;
  v_ok boolean;
begin
  select mode, status into v_mode, v_status
  from public.attempts
  where id = p_attempt
    and ((v_user is not null and user_id = v_user)
      or (v_user is null and user_id is null));

  if v_mode is null then raise exception 'Попытка не найдена'; end if;
  if v_status <> 'in_progress' then raise exception 'Попытка уже завершена'; end if;
  if not exists (
    select 1 from public.question_options
    where id = p_option and question_id = p_question
  ) then raise exception 'Неверный вариант ответа'; end if;

  select correct_option_id, explanation into v_key, v_expl
  from public.question_answers
  where question_id = p_question;

  v_ok := (v_key = p_option);

  update public.attempt_answers
  set chosen_option_id = p_option,
      is_correct = v_ok,
      answered_at = now()
  where attempt_id = p_attempt
    and question_id = p_question
    and answered_at is null;

  if not found then raise exception 'Вопрос не входит в попытку или уже отвечен'; end if;

  return jsonb_build_object(
    'recorded', true,
    'is_correct', v_ok,
    'correct_option_id', v_key,
    'explanation', v_expl
  );
end;
$$;


--
-- Name: delete_my_attempts(uuid[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_my_attempts(p_attempt_ids uuid[]) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_deleted integer := 0;
begin
  if auth.uid() is null then
    raise exception 'Требуется вход';
  end if;

  if p_attempt_ids is null or cardinality(p_attempt_ids) = 0 then
    return 0;
  end if;

  delete from public.attempts
   where user_id = auth.uid()
     and id = any(p_attempt_ids);

  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;


--
-- Name: finish_attempt(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finish_attempt(p_attempt uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_user uuid := auth.uid();
  v_status text;
  v_total integer;
  v_correct integer := 0;
  v_answered integer := 0;
begin
  select status, question_count
    into v_status, v_total
  from public.attempts
  where id = p_attempt and user_id = v_user
  for update;

  if v_status is null then raise exception 'Попытка не найдена'; end if;

  select count(*) filter (where chosen_option_id is not null)::integer,
         count(*) filter (where chosen_option_id is not null and is_correct is true)::integer
    into v_answered, v_correct
  from public.attempt_answers
  where attempt_id = p_attempt;

  update public.attempts
  set status = 'finished',
      finished_at = coalesce(finished_at, now()),
      correct_count = coalesce(v_correct, 0),
      duration_seconds = coalesce(duration_seconds, extract(epoch from now() - (select created_at from public.attempts where id = p_attempt))::integer)
  where id = p_attempt and user_id = v_user;

  return (
    select jsonb_build_object(
      'attempt_id', id,
      'status', status,
      'question_count', question_count,
      'answered_count', v_answered,
      'correct_count', correct_count,
      'percent', percent,
      'duration_seconds', duration_seconds
    )
    from public.attempts where id = p_attempt and user_id = v_user
  );
end;
$$;


--
-- Name: get_attempt_review(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_attempt_review(p_attempt uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: get_my_attempt_state(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_my_attempt_state(p_attempt_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_state jsonb;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select s.state into v_state
  from public.attempt_states s
  join public.attempts a on a.id = s.attempt_id
  where s.attempt_id = p_attempt_id
    and s.user_id = auth.uid()
    and a.user_id = auth.uid();

  return v_state;
end;
$$;


--
-- Name: get_my_attempt_stats(uuid[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_my_attempt_stats(p_attempt_ids uuid[]) RETURNS TABLE(attempt_id uuid, answered_count bigint, correct_count bigint)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select aa.attempt_id,
         count(*) filter (where aa.chosen_option_id is not null) as answered_count,
         count(*) filter (where aa.chosen_option_id is not null and aa.is_correct is true) as correct_count
  from public.attempt_answers aa
  join public.attempts a on a.id = aa.attempt_id
  where a.user_id = auth.uid()
    and aa.attempt_id = any(coalesce(p_attempt_ids, '{}'::uuid[]))
  group by aa.attempt_id;
$$;


--
--

CREATE FUNCTION public.is_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select exists(select 1 from public.admins where user_id = auth.uid());
$$;


--
-- Name: questions_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.questions_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
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


--
-- Name: resume_my_attempt(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resume_my_attempt(p_attempt uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_user uuid := auth.uid();
  v_owner uuid;
  v_status text;
  v_total integer;
  v_answered integer;
begin
  if v_user is null then
    raise exception 'Необходимо войти в аккаунт';
  end if;

  select user_id, status, question_count
    into v_owner, v_status, v_total
  from public.attempts
  where id = p_attempt
  for update;

  if not found or v_owner is distinct from v_user then
    raise exception 'Попытка не найдена';
  end if;

  select count(*) filter (where chosen_option_id is not null)::integer
    into v_answered
  from public.attempt_answers
  where attempt_id = p_attempt;

  if coalesce(v_answered, 0) >= coalesce(v_total, 0) then
    raise exception 'В этой попытке уже отвечены все вопросы';
  end if;

  if v_status is distinct from 'in_progress' then
    update public.attempts
       set status = 'in_progress',
           finished_at = null
     where id = p_attempt
       and user_id = v_user;
  end if;

  return jsonb_build_object(
    'attempt_id', p_attempt,
    'status', 'in_progress',
    'answered_count', coalesce(v_answered, 0),
    'question_count', coalesce(v_total, 0)
  );
end;
$$;


--
-- Name: save_my_attempt_state(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.save_my_attempt_state(p_attempt_id uuid, p_state jsonb) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'Authentication required';
  end if;
  if p_state is null or jsonb_typeof(p_state) <> 'object' then
    raise exception 'Invalid attempt state';
  end if;
  if not exists (
    select 1 from public.attempts a
    where a.id = p_attempt_id and a.user_id = v_user
  ) then
    raise exception 'Attempt not found or access denied';
  end if;

  insert into public.attempt_states(attempt_id, user_id, state, updated_at)
  values (p_attempt_id, v_user, p_state, now())
  on conflict (attempt_id) do update
    set state = public.attempt_states.state || excluded.state, updated_at = now()
    where public.attempt_states.user_id = v_user;

  return true;
end;
$$;


--
-- Name: start_attempt(text, bigint, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.start_attempt(p_mode text, p_topic_id bigint DEFAULT NULL::bigint, p_count integer DEFAULT 10) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_user uuid := auth.uid(); v_ids uuid[]; v_attempt uuid;
begin
  if p_mode not in ('macro','micro','theory','exam') then raise exception 'Неверный режим'; end if;
  -- До 100 000 вопросов для марафона; фактически выбираются только доступные вопросы.
  p_count := least(greatest(coalesce(p_count, 10), 1), 100000);

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


--
-- Name: start_favorites_attempt(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.start_favorites_attempt(p_count integer DEFAULT 20) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: start_single_question_attempt(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.start_single_question_attempt(p_question_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_user uuid := auth.uid();
  v_attempt uuid;
  v_question public.questions%rowtype;
begin
  if v_user is null then raise exception 'Войдите, чтобы решать вопросы из избранного'; end if;
  if not exists (select 1 from public.question_favorites f where f.user_id = v_user and f.question_id = p_question_id) then
    raise exception 'Вопрос не найден в вашем избранном';
  end if;
  select q.* into v_question
  from public.questions q
  where q.id = p_question_id and q.is_published
    and exists (select 1 from public.question_answers a where a.question_id = q.id);
  if not found then raise exception 'У вопроса нет доступных вариантов ответа'; end if;
  if (select count(*) from public.attempts where user_id = v_user and created_at > now() - interval '1 hour') >= 30 then
    raise exception 'Слишком много попыток за час, попробуйте позже';
  end if;
  insert into public.attempts(user_id, mode, topic_id, question_count, correct_count, status)
  values (v_user, 'favorites', v_question.topic_id, 1, 0, 'in_progress') returning id into v_attempt;
  insert into public.attempt_answers(attempt_id, question_id) values (v_attempt, v_question.id);
  return jsonb_build_object(
    'attempt_id', v_attempt,
    'questions', jsonb_build_array(jsonb_build_object(
      'id', v_question.id,
      'prompt', v_question.prompt,
      'image_path', v_question.image_path,
      'created_at', v_question.created_at,
      'options', (select jsonb_agg(jsonb_build_object('id', o.id, 'text', o.option_text) order by random())
                  from public.question_options o where o.question_id = v_question.id)
    ))
  );
end;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: admins; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admins (
    user_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: attempt_answers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.attempt_answers (
    id bigint NOT NULL,
    attempt_id uuid NOT NULL,
    question_id uuid NOT NULL,
    chosen_option_id uuid,
    is_correct boolean,
    answered_at timestamp with time zone
);


--
-- Name: attempt_answers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.attempt_answers ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.attempt_answers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: attempt_states; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.attempt_states (
    attempt_id uuid NOT NULL,
    user_id uuid NOT NULL,
    state jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.attempts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    mode text NOT NULL,
    topic_id bigint,
    question_count integer NOT NULL,
    correct_count integer DEFAULT 0 NOT NULL,
    percent numeric(5,2) GENERATED ALWAYS AS (round((((correct_count)::numeric * (100)::numeric) / (question_count)::numeric), 2)) STORED,
    duration_seconds integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    status text DEFAULT 'in_progress'::text NOT NULL,
    finished_at timestamp with time zone,
    CONSTRAINT attempts_check CHECK (((correct_count >= 0) AND (correct_count <= question_count))),
    CONSTRAINT attempts_duration_seconds_check CHECK (((duration_seconds IS NULL) OR (duration_seconds >= 0))),
    CONSTRAINT attempts_mode_check CHECK ((mode = ANY (ARRAY['macro'::text, 'micro'::text, 'theory'::text, 'exam'::text, 'favorites'::text]))),
    CONSTRAINT attempts_question_count_check CHECK ((question_count > 0)),
    CONSTRAINT attempts_status_check CHECK ((status = ANY (ARRAY['in_progress'::text, 'finished'::text])))
);


--
-- Name: profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profiles (
    id uuid NOT NULL,
    username text NOT NULL,
    nickname text NOT NULL,
    avatar_url text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT avatar_own_path CHECK (((avatar_url IS NULL) OR (avatar_url ~~ (('avatars/'::text || (id)::text) || '/%'::text)))),
    CONSTRAINT nickname_length CHECK (((char_length(nickname) >= 2) AND (char_length(nickname) <= 32))),
    CONSTRAINT username_format CHECK ((username ~ '^[a-z0-9_]{3,24}$'::text))
);


--
-- Name: leaderboard; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.leaderboard AS
 SELECT row_number() OVER (PARTITION BY category ORDER BY average_percent DESC, correct_answers DESC, attempts DESC) AS place,
    category,
    user_id,
    nickname,
    avatar_url,
    attempts,
    average_percent,
    correct_answers
   FROM ( SELECT
                CASE
                    WHEN (a.mode = ANY (ARRAY['macro'::text, 'exam'::text])) THEN 'macro'::text
                    ELSE a.mode
                END AS category,
            p.id AS user_id,
            p.nickname,
            p.avatar_url,
            (count(a.id))::integer AS attempts,
            round(avg(a.percent), 2) AS average_percent,
            sum(a.correct_count) AS correct_answers
           FROM (public.profiles p
             JOIN public.attempts a ON ((a.user_id = p.id)))
          WHERE ((a.status = 'finished'::text) AND (a.question_count >= 5))
          GROUP BY
                CASE
                    WHEN (a.mode = ANY (ARRAY['macro'::text, 'exam'::text])) THEN 'macro'::text
                    ELSE a.mode
                END, p.id, p.nickname, p.avatar_url
         HAVING (count(a.id) >= 3)) t;


--
-- Name: learning_materials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.learning_materials (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    kind text DEFAULT 'Другое'::text NOT NULL,
    title text NOT NULL,
    body text DEFAULT ''::text NOT NULL,
    url text,
    sort_order integer DEFAULT 0 NOT NULL,
    is_published boolean DEFAULT false NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    file_path text,
    file_name text,
    file_size bigint
);


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    title text NOT NULL,
    body text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    CONSTRAINT notifications_body_check CHECK (((body IS NULL) OR (char_length(body) <= 2000))),
    CONSTRAINT notifications_title_check CHECK (((char_length(title) >= 1) AND (char_length(title) <= 120)))
);


--
-- Name: question_answers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.question_answers (
    question_id uuid NOT NULL,
    correct_option_id uuid NOT NULL,
    explanation text
);


--
-- Name: question_comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.question_comments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    question_id uuid NOT NULL,
    user_id uuid NOT NULL,
    comment text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT question_comments_comment_check CHECK (((length(TRIM(BOTH FROM comment)) >= 1) AND (length(TRIM(BOTH FROM comment)) <= 3000)))
);


--
-- Name: question_favorites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.question_favorites (
    user_id uuid NOT NULL,
    question_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: question_options; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.question_options (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    question_id uuid NOT NULL,
    option_text text NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL
);


--
-- Name: question_trash; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.question_trash (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    question_id text NOT NULL,
    question_data jsonb NOT NULL,
    options_data jsonb DEFAULT '[]'::jsonb NOT NULL,
    answer_data jsonb,
    deleted_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_by uuid
);


--
-- Name: questions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.questions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    section text NOT NULL,
    block text NOT NULL,
    topic_id bigint,
    prompt text NOT NULL,
    image_path text,
    is_exam boolean DEFAULT false NOT NULL,
    is_published boolean DEFAULT false NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT exam_only_macro CHECK (((NOT is_exam) OR (section = 'macro'::text))),
    CONSTRAINT questions_block_check CHECK ((block = ANY (ARRAY['general'::text, 'specific'::text]))),
    CONSTRAINT questions_section_check CHECK ((section = ANY (ARRAY['macro'::text, 'micro'::text, 'theory'::text])))
);


--
-- Name: site_content; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.site_content (
    key text NOT NULL,
    value text DEFAULT ''::text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid
);


--
-- Name: topics; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.topics (
    id bigint NOT NULL,
    block text NOT NULL,
    title text NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    is_locked boolean DEFAULT false NOT NULL,
    is_locked_macro boolean DEFAULT false NOT NULL,
    is_locked_micro boolean DEFAULT false NOT NULL,
    is_locked_theory boolean DEFAULT false NOT NULL,
    CONSTRAINT topics_block_check CHECK ((block = ANY (ARRAY['general'::text, 'specific'::text])))
);


--
-- Name: topics_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.topics ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.topics_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: turntable_sets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.turntable_sets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    title text NOT NULL,
    frame_paths jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT turntable_frames_array CHECK ((jsonb_typeof(frame_paths) = 'array'::text))
);


--
-- Data for Name: admins; Type: TABLE DATA; Schema: public; Owner: -
--

-- Imported 1 rows into public.admins
INSERT INTO public.admins (user_id, created_at) VALUES
  (E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-22 16:34:24.094246+00');



--
-- Data for Name: attempt_answers; Type: TABLE DATA; Schema: public; Owner: -
--

-- Imported 135 rows into public.attempt_answers
INSERT INTO public.attempt_answers (id, attempt_id, question_id, chosen_option_id, is_correct, answered_at) VALUES
  (E'15841', E'1773e603-9863-4555-ad00-d3386e505d3d', E'7c368354-ed4d-4e5c-9f5a-235b531a3ad1', NULL, NULL, NULL),
  (E'15842', E'1773e603-9863-4555-ad00-d3386e505d3d', E'a9a95b68-fbe8-4001-abaf-1da0ea627370', NULL, NULL, NULL),
  (E'15843', E'1773e603-9863-4555-ad00-d3386e505d3d', E'81612ea5-581a-4671-9a40-dfc9df29c95a', NULL, NULL, NULL),
  (E'15973', E'9bcf5a10-c722-4358-abcd-ece92aa0676f', E'62af2f62-fcac-48bf-8618-5c18d44125d4', NULL, NULL, NULL),
  (E'15974', E'b22e80a4-6e82-4e46-80ef-224a35d85a18', E'c7a7cb27-38d6-45a3-8650-52dfa395a233', NULL, NULL, NULL),
  (E'220', E'b8924c3d-e6aa-45ea-aa54-5ef634b01771', E'f7e90987-c01e-46c5-9f9a-f09022ff1fb2', NULL, E't', E'2026-10-24 12:05:51.362045+00'),
  (E'225', E'1b4ef5a4-9903-4db6-8375-2f7ca1c2c0c4', E'f7e90987-c01e-46c5-9f9a-f09022ff1fb2', NULL, E't', E'2026-10-24 14:28:05.900125+00'),
  (E'219', E'b8924c3d-e6aa-45ea-aa54-5ef634b01771', E'bda40b0d-d4e6-496e-a2d0-ca19d0e38a76', NULL, E't', E'2026-10-24 12:05:36.640256+00'),
  (E'224', E'1b4ef5a4-9903-4db6-8375-2f7ca1c2c0c4', E'bda40b0d-d4e6-496e-a2d0-ca19d0e38a76', NULL, E'f', E'2026-10-24 14:27:58.500672+00'),
  (E'15975', E'b22e80a4-6e82-4e46-80ef-224a35d85a18', E'62af2f62-fcac-48bf-8618-5c18d44125d4', NULL, NULL, NULL),
  (E'221', E'b8924c3d-e6aa-45ea-aa54-5ef634b01771', E'6ba889cb-f5b3-40ba-8f03-8a2594888776', E'f6a70a15-7431-4f45-9356-4ec344bae385', E't', E'2026-10-24 12:05:25.735353+00'),
  (E'223', E'b8924c3d-e6aa-45ea-aa54-5ef634b01771', E'df8943c1-eeb5-4388-b407-1221c464d8d5', E'2a8f1c12-7d22-4991-afc3-f9e2561fc52e', E't', E'2026-10-24 12:06:12.01295+00'),
  (E'222', E'b8924c3d-e6aa-45ea-aa54-5ef634b01771', E'18bc9b49-e108-4248-abaf-5e169098cbea', E'fa682234-66d5-471f-88e0-eb8e1a62f359', E't', E'2026-10-24 12:06:26.070804+00'),
  (E'228', E'1b4ef5a4-9903-4db6-8375-2f7ca1c2c0c4', E'6ba889cb-f5b3-40ba-8f03-8a2594888776', E'f6a70a15-7431-4f45-9356-4ec344bae385', E't', E'2026-10-24 14:27:51.5416+00'),
  (E'226', E'1b4ef5a4-9903-4db6-8375-2f7ca1c2c0c4', E'df8943c1-eeb5-4388-b407-1221c464d8d5', E'2a8f1c12-7d22-4991-afc3-f9e2561fc52e', E't', E'2026-10-24 14:28:13.716908+00'),
  (E'227', E'1b4ef5a4-9903-4db6-8375-2f7ca1c2c0c4', E'18bc9b49-e108-4248-abaf-5e169098cbea', E'fa682234-66d5-471f-88e0-eb8e1a62f359', E't', E'2026-10-24 14:28:20.113014+00'),
  (E'15976', E'4253698e-a5c7-4eee-9dcc-b16a2350c2c4', E'c7a7cb27-38d6-45a3-8650-52dfa395a233', NULL, NULL, NULL),
  (E'15977', E'4253698e-a5c7-4eee-9dcc-b16a2350c2c4', E'7e04afcf-11c4-4fce-a076-f0e6c38903dc', NULL, NULL, NULL),
  (E'15978', E'4253698e-a5c7-4eee-9dcc-b16a2350c2c4', E'62af2f62-fcac-48bf-8618-5c18d44125d4', NULL, NULL, NULL),
  (E'15979', E'68e92580-e2ca-40f4-883d-a7f51fefc606', E'c7a7cb27-38d6-45a3-8650-52dfa395a233', NULL, NULL, NULL),
  (E'15980', E'68e92580-e2ca-40f4-883d-a7f51fefc606', E'7e04afcf-11c4-4fce-a076-f0e6c38903dc', NULL, NULL, NULL),
  (E'15981', E'68e92580-e2ca-40f4-883d-a7f51fefc606', E'62af2f62-fcac-48bf-8618-5c18d44125d4', NULL, NULL, NULL),
  (E'15982', E'68e92580-e2ca-40f4-883d-a7f51fefc606', E'9a29bd7c-180d-4661-9224-4f3a788ffc07', NULL, NULL, NULL),
  (E'15983', E'44f8e4fa-ff67-479b-9707-49a7f9e0cd9a', E'7c368354-ed4d-4e5c-9f5a-235b531a3ad1', NULL, NULL, NULL),
  (E'15984', E'44f8e4fa-ff67-479b-9707-49a7f9e0cd9a', E'a9a95b68-fbe8-4001-abaf-1da0ea627370', NULL, NULL, NULL),
  (E'15985', E'44f8e4fa-ff67-479b-9707-49a7f9e0cd9a', E'81612ea5-581a-4671-9a40-dfc9df29c95a', NULL, NULL, NULL),
  (E'15986', E'44f8e4fa-ff67-479b-9707-49a7f9e0cd9a', E'9a29bd7c-180d-4661-9224-4f3a788ffc07', NULL, NULL, NULL),
  (E'15489', E'2444b530-796c-4237-b4ad-307911346cb7', E'7c368354-ed4d-4e5c-9f5a-235b531a3ad1', NULL, NULL, NULL),
  (E'15490', E'2444b530-796c-4237-b4ad-307911346cb7', E'a9a95b68-fbe8-4001-abaf-1da0ea627370', NULL, NULL, NULL),
  (E'15491', E'2444b530-796c-4237-b4ad-307911346cb7', E'81612ea5-581a-4671-9a40-dfc9df29c95a', NULL, NULL, NULL),
  (E'15893', E'565751e3-dfcd-4079-9879-2c62b9093f71', E'7c368354-ed4d-4e5c-9f5a-235b531a3ad1', NULL, NULL, NULL),
  (E'15894', E'565751e3-dfcd-4079-9879-2c62b9093f71', E'a9a95b68-fbe8-4001-abaf-1da0ea627370', NULL, NULL, NULL),
  (E'15895', E'565751e3-dfcd-4079-9879-2c62b9093f71', E'81612ea5-581a-4671-9a40-dfc9df29c95a', NULL, NULL, NULL),
  (E'15814', E'895a5d09-6702-49bb-bd65-1f9f9181129b', E'7c368354-ed4d-4e5c-9f5a-235b531a3ad1', NULL, NULL, NULL),
  (E'15815', E'895a5d09-6702-49bb-bd65-1f9f9181129b', E'a9a95b68-fbe8-4001-abaf-1da0ea627370', NULL, NULL, NULL),
  (E'15816', E'895a5d09-6702-49bb-bd65-1f9f9181129b', E'81612ea5-581a-4671-9a40-dfc9df29c95a', NULL, NULL, NULL),
  (E'15903', E'81187607-d674-4ae8-b8e9-015aa9101af7', E'7c368354-ed4d-4e5c-9f5a-235b531a3ad1', NULL, NULL, NULL),
  (E'15904', E'81187607-d674-4ae8-b8e9-015aa9101af7', E'a9a95b68-fbe8-4001-abaf-1da0ea627370', NULL, NULL, NULL),
  (E'15905', E'81187607-d674-4ae8-b8e9-015aa9101af7', E'81612ea5-581a-4671-9a40-dfc9df29c95a', NULL, NULL, NULL),
  (E'1552', E'1b8c58f7-1d7f-4283-83d7-c51440e67ff9', E'7c368354-ed4d-4e5c-9f5a-235b531a3ad1', NULL, NULL, NULL),
  (E'1553', E'1b8c58f7-1d7f-4283-83d7-c51440e67ff9', E'a9a95b68-fbe8-4001-abaf-1da0ea627370', NULL, NULL, NULL),
  (E'1554', E'1b8c58f7-1d7f-4283-83d7-c51440e67ff9', E'81612ea5-581a-4671-9a40-dfc9df29c95a', NULL, NULL, NULL),
  (E'1555', E'f03b1d04-6056-435e-9917-78d765087ad7', E'7c07057a-982d-418f-abe5-c26649151f65', NULL, NULL, NULL),
  (E'1556', E'f03b1d04-6056-435e-9917-78d765087ad7', E'056d6796-3437-49aa-a2e1-8b83cb6e7f5e', NULL, NULL, NULL),
  (E'1557', E'f03b1d04-6056-435e-9917-78d765087ad7', E'c0edcfb3-1a0f-4254-98f7-1ada8b44efe7', NULL, NULL, NULL),
  (E'1558', E'f03b1d04-6056-435e-9917-78d765087ad7', E'e42319a0-9585-4068-aba3-dd3b082d9ee4', NULL, NULL, NULL),
  (E'1559', E'f03b1d04-6056-435e-9917-78d765087ad7', E'6b241cf2-b8f8-4400-80f0-a360cb7cd3a5', NULL, NULL, NULL),
  (E'1560', E'f03b1d04-6056-435e-9917-78d765087ad7', E'20294443-8ae8-45ac-8630-9e2a2f99fa78', NULL, NULL, NULL),
  (E'1561', E'f03b1d04-6056-435e-9917-78d765087ad7', E'6cad8663-d0e1-4068-9759-8c8aaedb4af6', NULL, NULL, NULL),
  (E'1562', E'f03b1d04-6056-435e-9917-78d765087ad7', E'73fb80e6-f5bc-475b-88df-beec0eaab466', NULL, NULL, NULL),
  (E'1563', E'f03b1d04-6056-435e-9917-78d765087ad7', E'3747c271-34e2-45d6-b17f-2f632a551caf', NULL, NULL, NULL),
  (E'1564', E'f03b1d04-6056-435e-9917-78d765087ad7', E'23d9a0da-077c-4473-94a6-498563bb8648', NULL, NULL, NULL),
  (E'1565', E'f03b1d04-6056-435e-9917-78d765087ad7', E'28ce84b0-e67a-43aa-b044-346551156287', NULL, NULL, NULL),
  (E'1566', E'f03b1d04-6056-435e-9917-78d765087ad7', E'2e2a902e-9d14-4769-9cde-75ae1a45f2d0', NULL, NULL, NULL),
  (E'1567', E'f03b1d04-6056-435e-9917-78d765087ad7', E'565e6acc-a394-41b7-88eb-22d04203af0e', NULL, NULL, NULL),
  (E'1568', E'f03b1d04-6056-435e-9917-78d765087ad7', E'2feb4438-9993-4275-b215-2f668234aa1a', NULL, NULL, NULL),
  (E'1569', E'f03b1d04-6056-435e-9917-78d765087ad7', E'565fc072-c314-493e-be35-44f815112ea2', NULL, NULL, NULL),
  (E'1570', E'f03b1d04-6056-435e-9917-78d765087ad7', E'9cf4ef72-6718-4de8-8272-11b9f08f0cdb', NULL, NULL, NULL),
  (E'1571', E'f03b1d04-6056-435e-9917-78d765087ad7', E'f6dd8320-e2a2-488e-afac-39b4a1fefb51', NULL, NULL, NULL),
  (E'1572', E'f03b1d04-6056-435e-9917-78d765087ad7', E'6ecdd62b-b2ea-49da-9926-e08e6caa0777', NULL, NULL, NULL),
  (E'1573', E'f03b1d04-6056-435e-9917-78d765087ad7', E'607a3ec4-af76-41b1-bd56-180f3eaaaaa5', NULL, NULL, NULL),
  (E'1574', E'f03b1d04-6056-435e-9917-78d765087ad7', E'3edd286e-256e-407f-8503-45a581a47503', NULL, NULL, NULL),
  (E'1575', E'f03b1d04-6056-435e-9917-78d765087ad7', E'1598e104-344b-4c98-864d-c980323c9da8', NULL, NULL, NULL),
  (E'1576', E'f03b1d04-6056-435e-9917-78d765087ad7', E'5f1aeae5-f81d-4545-b7b3-88d57c32ab2d', NULL, NULL, NULL),
  (E'1577', E'f03b1d04-6056-435e-9917-78d765087ad7', E'1158ed83-d7e2-49c3-8ddf-19e7a8eb9058', NULL, NULL, NULL),
  (E'1578', E'f03b1d04-6056-435e-9917-78d765087ad7', E'6a34858d-46d6-4feb-a7e1-3074ca386944', NULL, NULL, NULL),
  (E'1579', E'f03b1d04-6056-435e-9917-78d765087ad7', E'9ebc5e2c-4920-40a0-b7d3-ab16e505dfcb', NULL, NULL, NULL),
  (E'1580', E'f03b1d04-6056-435e-9917-78d765087ad7', E'68e51e1b-702e-4588-b7df-772ddb2d464f', NULL, NULL, NULL),
  (E'1581', E'f03b1d04-6056-435e-9917-78d765087ad7', E'8b9c9ac9-2217-4100-87df-861848f203de', NULL, NULL, NULL),
  (E'1582', E'f03b1d04-6056-435e-9917-78d765087ad7', E'bbdcdd6f-1b21-4b96-8f12-0cc0a129accd', NULL, NULL, NULL),
  (E'1583', E'f03b1d04-6056-435e-9917-78d765087ad7', E'4fc7082f-3ac6-4f7c-94af-da5c21cfc181', NULL, NULL, NULL),
  (E'1584', E'f03b1d04-6056-435e-9917-78d765087ad7', E'39186242-e6ca-4219-b0ea-9270624810d8', NULL, NULL, NULL),
  (E'1688', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'e42319a0-9585-4068-aba3-dd3b082d9ee4', NULL, NULL, NULL),
  (E'1689', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'6b241cf2-b8f8-4400-80f0-a360cb7cd3a5', NULL, NULL, NULL),
  (E'1690', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'20294443-8ae8-45ac-8630-9e2a2f99fa78', NULL, NULL, NULL),
  (E'1691', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'6cad8663-d0e1-4068-9759-8c8aaedb4af6', NULL, NULL, NULL),
  (E'1692', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'73fb80e6-f5bc-475b-88df-beec0eaab466', NULL, NULL, NULL),
  (E'1693', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'3747c271-34e2-45d6-b17f-2f632a551caf', NULL, NULL, NULL),
  (E'1694', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'23d9a0da-077c-4473-94a6-498563bb8648', NULL, NULL, NULL),
  (E'1695', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'28ce84b0-e67a-43aa-b044-346551156287', NULL, NULL, NULL),
  (E'1696', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'2e2a902e-9d14-4769-9cde-75ae1a45f2d0', NULL, NULL, NULL),
  (E'1697', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'565e6acc-a394-41b7-88eb-22d04203af0e', NULL, NULL, NULL),
  (E'1698', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'2feb4438-9993-4275-b215-2f668234aa1a', NULL, NULL, NULL),
  (E'1699', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'565fc072-c314-493e-be35-44f815112ea2', NULL, NULL, NULL),
  (E'1700', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'9cf4ef72-6718-4de8-8272-11b9f08f0cdb', NULL, NULL, NULL),
  (E'1701', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'f6dd8320-e2a2-488e-afac-39b4a1fefb51', NULL, NULL, NULL),
  (E'1702', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'6ecdd62b-b2ea-49da-9926-e08e6caa0777', NULL, NULL, NULL),
  (E'1703', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'607a3ec4-af76-41b1-bd56-180f3eaaaaa5', NULL, NULL, NULL),
  (E'1704', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'3edd286e-256e-407f-8503-45a581a47503', NULL, NULL, NULL),
  (E'1705', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'1598e104-344b-4c98-864d-c980323c9da8', NULL, NULL, NULL),
  (E'1706', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'5f1aeae5-f81d-4545-b7b3-88d57c32ab2d', NULL, NULL, NULL),
  (E'1707', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'1158ed83-d7e2-49c3-8ddf-19e7a8eb9058', NULL, NULL, NULL),
  (E'1708', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'6a34858d-46d6-4feb-a7e1-3074ca386944', NULL, NULL, NULL),
  (E'1709', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'9ebc5e2c-4920-40a0-b7d3-ab16e505dfcb', NULL, NULL, NULL),
  (E'1710', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'68e51e1b-702e-4588-b7df-772ddb2d464f', NULL, NULL, NULL),
  (E'1711', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'8b9c9ac9-2217-4100-87df-861848f203de', NULL, NULL, NULL),
  (E'1712', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'bbdcdd6f-1b21-4b96-8f12-0cc0a129accd', NULL, NULL, NULL),
  (E'1713', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'4fc7082f-3ac6-4f7c-94af-da5c21cfc181', NULL, NULL, NULL),
  (E'1714', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'39186242-e6ca-4219-b0ea-9270624810d8', NULL, NULL, NULL),
  (E'1685', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'7c07057a-982d-418f-abe5-c26649151f65', E'83b329a1-925f-4dbe-b564-846308359244', E't', E'2026-10-25 21:06:26.005712+00');
INSERT INTO public.attempt_answers (id, attempt_id, question_id, chosen_option_id, is_correct, answered_at) VALUES
  (E'1686', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'056d6796-3437-49aa-a2e1-8b83cb6e7f5e', E'2484ccc4-1353-4067-9e75-c81c14f00ea9', E't', E'2026-10-25 21:06:31.025035+00'),
  (E'1687', E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'c0edcfb3-1a0f-4254-98f7-1ada8b44efe7', E'32d25f67-dc07-4512-b8e4-6918f669469e', E't', E'2026-10-25 21:06:38.703358+00'),
  (E'15838', E'136008d5-3a12-457e-98e5-07d640a9ea83', E'7c368354-ed4d-4e5c-9f5a-235b531a3ad1', NULL, NULL, NULL),
  (E'15839', E'136008d5-3a12-457e-98e5-07d640a9ea83', E'a9a95b68-fbe8-4001-abaf-1da0ea627370', NULL, NULL, NULL),
  (E'15840', E'136008d5-3a12-457e-98e5-07d640a9ea83', E'81612ea5-581a-4671-9a40-dfc9df29c95a', NULL, NULL, NULL),
  (E'2755', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'7c07057a-982d-418f-abe5-c26649151f65', NULL, NULL, NULL),
  (E'2756', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'056d6796-3437-49aa-a2e1-8b83cb6e7f5e', NULL, NULL, NULL),
  (E'2757', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'c0edcfb3-1a0f-4254-98f7-1ada8b44efe7', NULL, NULL, NULL),
  (E'2758', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'e42319a0-9585-4068-aba3-dd3b082d9ee4', NULL, NULL, NULL),
  (E'2759', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'6b241cf2-b8f8-4400-80f0-a360cb7cd3a5', NULL, NULL, NULL),
  (E'2760', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'20294443-8ae8-45ac-8630-9e2a2f99fa78', NULL, NULL, NULL),
  (E'2761', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'6cad8663-d0e1-4068-9759-8c8aaedb4af6', NULL, NULL, NULL),
  (E'2762', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'73fb80e6-f5bc-475b-88df-beec0eaab466', NULL, NULL, NULL),
  (E'2763', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'3747c271-34e2-45d6-b17f-2f632a551caf', NULL, NULL, NULL),
  (E'2764', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'23d9a0da-077c-4473-94a6-498563bb8648', NULL, NULL, NULL),
  (E'2765', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'28ce84b0-e67a-43aa-b044-346551156287', NULL, NULL, NULL),
  (E'2766', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'2e2a902e-9d14-4769-9cde-75ae1a45f2d0', NULL, NULL, NULL),
  (E'2767', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'565e6acc-a394-41b7-88eb-22d04203af0e', NULL, NULL, NULL),
  (E'2768', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'2feb4438-9993-4275-b215-2f668234aa1a', NULL, NULL, NULL),
  (E'2770', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'9cf4ef72-6718-4de8-8272-11b9f08f0cdb', NULL, NULL, NULL),
  (E'2771', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'f6dd8320-e2a2-488e-afac-39b4a1fefb51', NULL, NULL, NULL),
  (E'2772', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'6ecdd62b-b2ea-49da-9926-e08e6caa0777', NULL, NULL, NULL),
  (E'2773', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'607a3ec4-af76-41b1-bd56-180f3eaaaaa5', NULL, NULL, NULL),
  (E'2774', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'3edd286e-256e-407f-8503-45a581a47503', NULL, NULL, NULL),
  (E'2775', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'1598e104-344b-4c98-864d-c980323c9da8', NULL, NULL, NULL),
  (E'2776', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'5f1aeae5-f81d-4545-b7b3-88d57c32ab2d', NULL, NULL, NULL),
  (E'2777', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'1158ed83-d7e2-49c3-8ddf-19e7a8eb9058', NULL, NULL, NULL),
  (E'2778', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'6a34858d-46d6-4feb-a7e1-3074ca386944', NULL, NULL, NULL),
  (E'2779', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'9ebc5e2c-4920-40a0-b7d3-ab16e505dfcb', NULL, NULL, NULL),
  (E'2780', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'68e51e1b-702e-4588-b7df-772ddb2d464f', NULL, NULL, NULL),
  (E'2781', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'8b9c9ac9-2217-4100-87df-861848f203de', NULL, NULL, NULL),
  (E'2782', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'bbdcdd6f-1b21-4b96-8f12-0cc0a129accd', NULL, NULL, NULL),
  (E'2783', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'4fc7082f-3ac6-4f7c-94af-da5c21cfc181', NULL, NULL, NULL),
  (E'2784', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'39186242-e6ca-4219-b0ea-9270624810d8', NULL, NULL, NULL),
  (E'2769', E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'565fc072-c314-493e-be35-44f815112ea2', E'a6f18c0c-a1ee-455d-a5fc-f533d80425ba', E'f', E'2026-10-26 02:55:09.938173+00');



--
-- Data for Name: attempt_states; Type: TABLE DATA; Schema: public; Owner: -
--

-- Imported 20 rows into public.attempt_states
INSERT INTO public.attempt_states (attempt_id, user_id, state, updated_at) VALUES
  (E'1773e603-9863-4555-ad00-d3386e505d3d', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'{"i": 0, "id": "1773e603-9863-4555-ad00-d3386e505d3d", "qs": [{"id": "a9a95b68-fbe8-4001-abaf-1da0ea627370", "prompt": "Определи патологию.", "options": [{"id": "fe735722-b33b-49d9-89fd-3927e184eeb4", "text": "Аденоматозный полип толстой кишки"}, {"id": "7314237b-7964-4f58-9c7f-68b732a474ad", "text": "Гиперпластический полип"}, {"id": "f42dc7ac-8d49-46e6-b53c-048c90ddcd36", "text": "Аденоматозный полип желудка"}, {"id": "e4b48e0c-de5f-4649-8c0f-87b8227e382f", "text": "Дивертикул Меккеля"}], "created_at": "2026-10-22T18:43:02.531354+00:00", "image_path": "questions/34d6520a-0e51-4ed2-bad3-bc8b74b6e410.jpg"}, {"id": "7c368354-ed4d-4e5c-9f5a-235b531a3ad1", "prompt": "Пациентка 67 лет. Страдала от прогрессирующего запора, вздутия живота, слабости и потери аппетита. Определи патологию.", "options": [{"id": "4df5c206-3646-42ec-83cb-6e00accdaccd", "text": "Аденоматозный полип толстой кишки"}, {"id": "d4a7270c-dfed-4416-89ec-fad2be40fb62", "text": "Аденокарцинома желудка"}, {"id": "17a31d69-36aa-42ec-b188-762f707d9992", "text": "Аденокарцинома толстой кишки"}, {"id": "93b27970-86b9-4cb8-8875-8cbe3a79353e", "text": "Дивертикулез"}], "created_at": "2026-10-22T18:28:18.627227+00:00", "image_path": "questions/cc3558f5-32b6-459a-bfc7-6498568e3113.jpg"}, {"id": "81612ea5-581a-4671-9a40-dfc9df29c95a", "prompt": "Определи патологию.", "options": [{"id": "3db29956-81e8-457a-9c38-683cf85e9569", "text": "Аденокарцинома из ворсинчатой ​​аденомы"}, {"id": "583c56a9-63ee-4b14-bf3b-8d7f32052080", "text": "Одиночный дивертикул ободочной кишки"}, {"id": "bdd57ec8-a5dc-47a3-bf39-f323e04aeb1a", "text": "Гиперпластический полип"}, {"id": "3329a09e-4807-4542-92b4-7d9103e6437e", "text": "Лимфофолликулярная гиперплазия слизистой оболочки"}], "created_at": "2026-10-23T10:54:09.657298+00:00", "image_path": "questions/ecb319d1-77f3-469a-a250-98e65e001501.jpg"}], "t0": 1795287683005, "mode": "macro", "answers": {}, "savedAt": 1795287683005, "marathon": false, "taskOrder": [], "isMarathon": false, "optionOrder": {}, "showAllNumbers": false}', E'2026-11-21 19:01:23.223235+00'),
  (E'4253698e-a5c7-4eee-9dcc-b16a2350c2c4', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'{"i": 0, "id": "4253698e-a5c7-4eee-9dcc-b16a2350c2c4", "qs": [{"id": "7e04afcf-11c4-4fce-a076-f0e6c38903dc", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "33acdbea-ce31-44b6-84f4-e0c2ff169a3f", "text": "Вариант ответа 1"}, {"id": "3bd80f1a-4836-4b43-a035-2dc65923d7d8", "text": "Вариант ответа 2"}, {"id": "6caeb4f5-176c-4fb9-a326-5bae6cd7599e", "text": "Вариант ответа 3"}, {"id": "9995ae5a-b74f-4c01-8ae1-e57f42b6c33b", "text": "Вариант ответа 4"}], "created_at": "2026-11-21T22:50:33.456955+00:00", "image_path": "360:storage:46c6dda2-ea5e-4540-a329-3e2e1ec88ad3"}, {"id": "62af2f62-fcac-48bf-8618-5c18d44125d4", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "2c4d8af2-5abd-49f3-b329-744d81a1c4d1", "text": "Вариант ответа 1"}, {"id": "6fbc983d-b23d-49da-8a42-9209903fe698", "text": "Вариант ответа 2"}, {"id": "01ecb5b4-e0b3-4181-9ac7-d2e7ecc79ad6", "text": "Вариант ответа 3"}, {"id": "5b772eb9-3883-4aae-8e75-045366005052", "text": "Вариант ответа 4"}], "created_at": "2026-11-21T22:39:58.467664+00:00", "image_path": "360:storage:4efcd4a8-c8e4-488a-955a-2cf97aae40f2"}, {"id": "c7a7cb27-38d6-45a3-8650-52dfa395a233", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "218a7943-188a-4245-b828-f2a07a0f8bf4", "text": "Вариант ответа 1"}, {"id": "88992732-ce97-4a89-a4a7-d8dfa1371f90", "text": "Вариант ответа 2"}, {"id": "fa528847-2f5a-40c9-bc98-9aaa4d9510d1", "text": "Вариант ответа 3"}, {"id": "cbdefd83-96ad-4876-be26-f4d5d280ed3f", "text": "Вариант ответа 4"}], "created_at": "2026-11-21T22:43:25.384869+00:00", "image_path": "360:storage:5d0e5d32-e2ac-4717-a802-fea5d41bae26"}], "t0": 1795301446781, "mode": "exam", "answers": {}, "savedAt": 1795301487150, "marathon": false, "taskOrder": [["7e04afcf-11c4-4fce-a076-f0e6c38903dc"], ["c7a7cb27-38d6-45a3-8650-52dfa395a233"], ["62af2f62-fcac-48bf-8618-5c18d44125d4"]], "isMarathon": false, "optionOrder": {"7e04afcf-11c4-4fce-a076-f0e6c38903dc": ["3bd80f1a-4836-4b43-a035-2dc65923d7d8", "9995ae5a-b74f-4c01-8ae1-e57f42b6c33b", "6caeb4f5-176c-4fb9-a326-5bae6cd7599e", "33acdbea-ce31-44b6-84f4-e0c2ff169a3f"], "c7a7cb27-38d6-45a3-8650-52dfa395a233": ["88992732-ce97-4a89-a4a7-d8dfa1371f90", "218a7943-188a-4245-b828-f2a07a0f8bf4", "cbdefd83-96ad-4876-be26-f4d5d280ed3f", "fa528847-2f5a-40c9-bc98-9aaa4d9510d1"]}, "showAllNumbers": false}', E'2026-11-21 22:51:27.173661+00'),
  (E'b9b3849c-48fd-4290-9150-94150e989f07', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'{"i": 1, "id": "b9b3849c-48fd-4290-9150-94150e989f07", "qs": [{"id": "0922a960-a89d-4bde-b07e-6821a6cd42ad", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "3dafc49f-9595-4f06-ae0b-3f4a8ced50e3", "text": "Себорейный кератоз"}, {"id": "e794dae6-8ee0-4bcb-ad36-b9c44c222e7f", "text": "Лимфаденит"}, {"id": "ed01131e-e37e-4d32-a92e-40ee0156a77e", "text": "Папиллярный рак почки"}, {"id": "406c1fe1-8266-410f-b3c6-973fa16564a5", "text": "Папиллома кожи"}], "created_at": "2026-11-19T17:51:28.58288+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}, {"id": "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d", "prompt": "Какой ТПП?", "options": [{"id": "14cfd792-4774-4394-a1ed-4f30ae1dd468", "text": "Воспаление"}, {"id": "f2dea413-8ed3-4d41-a922-293be38a200d", "text": "Опухоль"}, {"id": "22b8c237-4618-46dd-80d1-ebc4c2393681", "text": "Приспособление"}, {"id": "63079ea7-a66e-4f59-9ded-0e9a2dbcd12f", "text": "Нарушение кровообращения"}], "created_at": "2026-11-19T18:50:04.062365+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}, {"id": "886b3875-96f5-49e2-8f9b-256823c92515", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "da3be6e9-83c5-47ad-8c64-dd5f7f475b26", "text": "Вариант ответа 1"}, {"id": "b1f7ac4e-4551-4848-a2e1-d42a37d454a0", "text": "Вариант ответа 2"}, {"id": "b4815109-2d87-4005-9e6a-1ea04631d201", "text": "Вариант ответа 3"}, {"id": "4557c749-b07d-49c5-8344-ce9bf93aa4d5", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T20:23:10.922682+00:00", "image_path": "360:storage:41e81338-a044-492b-b615-f78ca01c0fdb"}, {"id": "3c8cf418-8d80-477b-b431-ecb0d894486b", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "daa3cc4b-de16-4484-a354-069297e94a5c", "text": "Вариант ответа 1"}, {"id": "78d4fe78-d6aa-4de3-b709-04399f3d0ae9", "text": "Вариант ответа 2"}, {"id": "fa066726-5c57-4bd4-af52-892e2ba7e7e6", "text": "Вариант ответа 3"}, {"id": "b31e0669-ab25-40f0-b7b0-76086025d2b5", "text": "Вариант ответа 4"}], "created_at": "2026-11-20T00:37:13.071227+00:00", "image_path": "360:storage:68f4f4ca-412d-44ab-b86b-e3b6d10a4333"}, {"id": "3ff4a71b-dbe7-43cc-aed9-f4032c3f5912", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "1986638c-76b2-4d25-b0d6-23fc06da51e3", "text": "Вариант ответа 1"}, {"id": "a55d9ba4-acd9-4d30-9946-6ddae52fab24", "text": "Вариант ответа 2"}, {"id": "4d5caf12-0864-4fd8-b371-f63b77ca04a0", "text": "Вариант ответа 3"}, {"id": "a83bfe05-85ae-49c4-94c1-867bc74afdd9", "text": "Вариант ответа 4"}], "created_at": "2026-11-20T00:29:15.640366+00:00", "image_path": "360:storage:7c2aa764-945c-4f17-8874-c9407aa67a54"}, {"id": "a7a51068-6b31-40be-a10d-3cce26fee416", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "8a3f3572-0953-4599-9e98-cf48f408da06", "text": "Вариант ответа 1"}, {"id": "159027a3-5d4d-4e31-870c-57c19c042923", "text": "Вариант ответа 2"}, {"id": "c4d7068b-094b-4405-b284-1497ddc9085f", "text": "Вариант ответа 3"}, {"id": "eb8e51b9-9860-49ba-8400-4d096bc18272", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T20:33:07.011062+00:00", "image_path": "360:storage:ac0a0540-391b-4c47-a56f-75df0d53416d"}, {"id": "b384f160-6a8d-422c-abb8-dba32e3d78f9", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "d3e13b45-dad9-441c-860f-61c8160745e5", "text": "Вариант ответа 1"}, {"id": "22fa84a1-110c-4a9e-9af3-03fad983bbb9", "text": "Вариант ответа 2"}, {"id": "3ba99ae7-f025-47d3-b61f-3bfade562e57", "text": "Вариант ответа 3"}, {"id": "ee84e230-d213-435c-8ff8-f4e49ae25363", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T19:55:14.432145+00:00", "image_path": "360:storage:c3361ad1-0cf7-48a6-80eb-2f6010842e88"}], "t0": 1795293816725, "mode": "exam", "answers": {}, "savedAt": 1795293845693, "marathon": false, "taskOrder": [["b384f160-6a8d-422c-abb8-dba32e3d78f9"], ["0922a960-a89d-4bde-b07e-6821a6cd42ad", "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d"], ["3ff4a71b-dbe7-43cc-aed9-f4032c3f5912"], ["886b3875-96f5-49e2-8f9b-256823c92515"], ["3c8cf418-8d80-477b-b431-ecb0d894486b"], ["a7a51068-6b31-40be-a10d-3cce26fee416"]], "isMarathon": false, "optionOrder": {"0922a960-a89d-4bde-b07e-6821a6cd42ad": ["3dafc49f-9595-4f06-ae0b-3f4a8ced50e3", "406c1fe1-8266-410f-b3c6-973fa16564a5", "ed01131e-e37e-4d32-a92e-40ee0156a77e", "e794dae6-8ee0-4bcb-ad36-b9c44c222e7f"], "3c8cf418-8d80-477b-b431-ecb0d894486b": ["daa3cc4b-de16-4484-a354-069297e94a5c", "78d4fe78-d6aa-4de3-b709-04399f3d0ae9", "b31e0669-ab25-40f0-b7b0-76086025d2b5", "fa066726-5c57-4bd4-af52-892e2ba7e7e6"], "3ff4a71b-dbe7-43cc-aed9-f4032c3f5912": ["4d5caf12-0864-4fd8-b371-f63b77ca04a0", "1986638c-76b2-4d25-b0d6-23fc06da51e3", "a83bfe05-85ae-49c4-94c1-867bc74afdd9", "a55d9ba4-acd9-4d30-9946-6ddae52fab24"], "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d": ["f2dea413-8ed3-4d41-a922-293be38a200d", "14cfd792-4774-4394-a1ed-4f30ae1dd468", "63079ea7-a66e-4f59-9ded-0e9a2dbcd12f", "22b8c237-4618-46dd-80d1-ebc4c2393681"], "886b3875-96f5-49e2-8f9b-256823c92515": ["da3be6e9-83c5-47ad-8c64-dd5f7f475b26", "b4815109-2d87-4005-9e6a-1ea04631d201", "4557c749-b07d-49c5-8344-ce9bf93aa4d5", "b1f7ac4e-4551-4848-a2e1-d42a37d454a0"], "a7a51068-6b31-40be-a10d-3cce26fee416": ["eb8e51b9-9860-49ba-8400-4d096bc18272", "159027a3-5d4d-4e31-870c-57c19c042923", "8a3f3572-0953-4599-9e98-cf48f408da06", "c4d7068b-094b-4405-b284-1497ddc9085f"], "b384f160-6a8d-422c-abb8-dba32e3d78f9": ["22fa84a1-110c-4a9e-9af3-03fad983bbb9", "ee84e230-d213-435c-8ff8-f4e49ae25363", "d3e13b45-dad9-441c-860f-61c8160745e5", "3ba99ae7-f025-47d3-b61f-3bfade562e57"]}, "showAllNumbers": true}', E'2026-11-21 20:44:05.912724+00'),
  (E'99cacf05-0d22-4544-bf3f-23b6eff8d863', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'{"i": 6, "id": "99cacf05-0d22-4544-bf3f-23b6eff8d863", "qs": [{"id": "0922a960-a89d-4bde-b07e-6821a6cd42ad", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "3dafc49f-9595-4f06-ae0b-3f4a8ced50e3", "text": "Себорейный кератоз"}, {"id": "e794dae6-8ee0-4bcb-ad36-b9c44c222e7f", "text": "Лимфаденит"}, {"id": "ed01131e-e37e-4d32-a92e-40ee0156a77e", "text": "Папиллярный рак почки"}, {"id": "406c1fe1-8266-410f-b3c6-973fa16564a5", "text": "Папиллома кожи"}], "created_at": "2026-11-19T17:51:28.58288+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}, {"id": "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d", "prompt": "Какой ТПП?", "options": [{"id": "14cfd792-4774-4394-a1ed-4f30ae1dd468", "text": "Воспаление"}, {"id": "f2dea413-8ed3-4d41-a922-293be38a200d", "text": "Опухоль"}, {"id": "22b8c237-4618-46dd-80d1-ebc4c2393681", "text": "Приспособление"}, {"id": "63079ea7-a66e-4f59-9ded-0e9a2dbcd12f", "text": "Нарушение кровообращения"}], "created_at": "2026-11-19T18:50:04.062365+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}, {"id": "886b3875-96f5-49e2-8f9b-256823c92515", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "da3be6e9-83c5-47ad-8c64-dd5f7f475b26", "text": "Вариант ответа 1"}, {"id": "b1f7ac4e-4551-4848-a2e1-d42a37d454a0", "text": "Вариант ответа 2"}, {"id": "b4815109-2d87-4005-9e6a-1ea04631d201", "text": "Вариант ответа 3"}, {"id": "4557c749-b07d-49c5-8344-ce9bf93aa4d5", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T20:23:10.922682+00:00", "image_path": "360:storage:41e81338-a044-492b-b615-f78ca01c0fdb"}, {"id": "2731f61d-078c-43be-843f-9c82c6505bcc", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "2fa81cb4-db4f-4803-b184-8d762c23cb30", "text": "Вариант ответа 1"}, {"id": "9f504a45-7409-4356-8871-0ddd8efe8555", "text": "Вариант ответа 2"}, {"id": "d4f5044e-f94c-44b5-839f-1081f68d7b1e", "text": "Вариант ответа 3"}, {"id": "00bf0558-e357-49e4-9779-a3d007a34b75", "text": "Вариант ответа 4"}], "created_at": "2026-11-21T20:42:35.075409+00:00", "image_path": "360:storage:426387d4-e6c1-40de-8b96-146233c5086a"}, {"id": "3c8cf418-8d80-477b-b431-ecb0d894486b", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "daa3cc4b-de16-4484-a354-069297e94a5c", "text": "Вариант ответа 1"}, {"id": "78d4fe78-d6aa-4de3-b709-04399f3d0ae9", "text": "Вариант ответа 2"}, {"id": "fa066726-5c57-4bd4-af52-892e2ba7e7e6", "text": "Вариант ответа 3"}, {"id": "b31e0669-ab25-40f0-b7b0-76086025d2b5", "text": "Вариант ответа 4"}], "created_at": "2026-11-20T00:37:13.071227+00:00", "image_path": "360:storage:68f4f4ca-412d-44ab-b86b-e3b6d10a4333"}, {"id": "3ff4a71b-dbe7-43cc-aed9-f4032c3f5912", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "1986638c-76b2-4d25-b0d6-23fc06da51e3", "text": "Вариант ответа 1"}, {"id": "a55d9ba4-acd9-4d30-9946-6ddae52fab24", "text": "Вариант ответа 2"}, {"id": "4d5caf12-0864-4fd8-b371-f63b77ca04a0", "text": "Вариант ответа 3"}, {"id": "a83bfe05-85ae-49c4-94c1-867bc74afdd9", "text": "Вариант ответа 4"}], "created_at": "2026-11-20T00:29:15.640366+00:00", "image_path": "360:storage:7c2aa764-945c-4f17-8874-c9407aa67a54"}, {"id": "a7a51068-6b31-40be-a10d-3cce26fee416", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "8a3f3572-0953-4599-9e98-cf48f408da06", "text": "Вариант ответа 1"}, {"id": "159027a3-5d4d-4e31-870c-57c19c042923", "text": "Вариант ответа 2"}, {"id": "c4d7068b-094b-4405-b284-1497ddc9085f", "text": "Вариант ответа 3"}, {"id": "eb8e51b9-9860-49ba-8400-4d096bc18272", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T20:33:07.011062+00:00", "image_path": "360:storage:ac0a0540-391b-4c47-a56f-75df0d53416d"}, {"id": "b384f160-6a8d-422c-abb8-dba32e3d78f9", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "d3e13b45-dad9-441c-860f-61c8160745e5", "text": "Вариант ответа 1"}, {"id": "22fa84a1-110c-4a9e-9af3-03fad983bbb9", "text": "Вариант ответа 2"}, {"id": "3ba99ae7-f025-47d3-b61f-3bfade562e57", "text": "Вариант ответа 3"}, {"id": "ee84e230-d213-435c-8ff8-f4e49ae25363", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T19:55:14.432145+00:00", "image_path": "360:storage:c3361ad1-0cf7-48a6-80eb-2f6010842e88"}], "t0": 1795293851490, "mode": "exam", "answers": {}, "savedAt": 1795298197062, "marathon": false, "taskOrder": [["0922a960-a89d-4bde-b07e-6821a6cd42ad", "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d"], ["a7a51068-6b31-40be-a10d-3cce26fee416"], ["3c8cf418-8d80-477b-b431-ecb0d894486b"], ["886b3875-96f5-49e2-8f9b-256823c92515"], ["3ff4a71b-dbe7-43cc-aed9-f4032c3f5912"], ["b384f160-6a8d-422c-abb8-dba32e3d78f9"], ["2731f61d-078c-43be-843f-9c82c6505bcc"]], "isMarathon": false, "optionOrder": {"0922a960-a89d-4bde-b07e-6821a6cd42ad": ["3dafc49f-9595-4f06-ae0b-3f4a8ced50e3", "e794dae6-8ee0-4bcb-ad36-b9c44c222e7f", "406c1fe1-8266-410f-b3c6-973fa16564a5", "ed01131e-e37e-4d32-a92e-40ee0156a77e"], "2731f61d-078c-43be-843f-9c82c6505bcc": ["00bf0558-e357-49e4-9779-a3d007a34b75", "2fa81cb4-db4f-4803-b184-8d762c23cb30", "d4f5044e-f94c-44b5-839f-1081f68d7b1e", "9f504a45-7409-4356-8871-0ddd8efe8555"], "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d": ["f2dea413-8ed3-4d41-a922-293be38a200d", "14cfd792-4774-4394-a1ed-4f30ae1dd468", "22b8c237-4618-46dd-80d1-ebc4c2393681", "63079ea7-a66e-4f59-9ded-0e9a2dbcd12f"]}, "showAllNumbers": false}', E'2026-11-21 21:56:37.192482+00'),
  (E'b22e80a4-6e82-4e46-80ef-224a35d85a18', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'{"i": 0, "id": "b22e80a4-6e82-4e46-80ef-224a35d85a18", "qs": [{"id": "62af2f62-fcac-48bf-8618-5c18d44125d4", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "2c4d8af2-5abd-49f3-b329-744d81a1c4d1", "text": "Вариант ответа 1"}, {"id": "6fbc983d-b23d-49da-8a42-9209903fe698", "text": "Вариант ответа 2"}, {"id": "01ecb5b4-e0b3-4181-9ac7-d2e7ecc79ad6", "text": "Вариант ответа 3"}, {"id": "5b772eb9-3883-4aae-8e75-045366005052", "text": "Вариант ответа 4"}], "created_at": "2026-11-21T22:39:58.467664+00:00", "image_path": "360:storage:4efcd4a8-c8e4-488a-955a-2cf97aae40f2"}, {"id": "c7a7cb27-38d6-45a3-8650-52dfa395a233", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "218a7943-188a-4245-b828-f2a07a0f8bf4", "text": "Вариант ответа 1"}, {"id": "88992732-ce97-4a89-a4a7-d8dfa1371f90", "text": "Вариант ответа 2"}, {"id": "fa528847-2f5a-40c9-bc98-9aaa4d9510d1", "text": "Вариант ответа 3"}, {"id": "cbdefd83-96ad-4876-be26-f4d5d280ed3f", "text": "Вариант ответа 4"}], "created_at": "2026-11-21T22:43:25.384869+00:00", "image_path": "360:storage:5d0e5d32-e2ac-4717-a802-fea5d41bae26"}], "t0": 1795301332166, "mode": "exam", "answers": {}, "savedAt": 1795301692245, "marathon": false, "taskOrder": [["c7a7cb27-38d6-45a3-8650-52dfa395a233"], ["62af2f62-fcac-48bf-8618-5c18d44125d4"]], "isMarathon": false, "optionOrder": {"c7a7cb27-38d6-45a3-8650-52dfa395a233": ["fa528847-2f5a-40c9-bc98-9aaa4d9510d1", "218a7943-188a-4245-b828-f2a07a0f8bf4", "cbdefd83-96ad-4876-be26-f4d5d280ed3f", "88992732-ce97-4a89-a4a7-d8dfa1371f90"]}, "showAllNumbers": false}', E'2026-11-21 22:54:52.228508+00'),
  (E'6e871a06-fbf9-44cb-968b-7fd7cff49887', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'{"i": 0, "id": "6e871a06-fbf9-44cb-968b-7fd7cff49887", "qs": [{"id": "0922a960-a89d-4bde-b07e-6821a6cd42ad", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "3dafc49f-9595-4f06-ae0b-3f4a8ced50e3", "text": "Себорейный кератоз"}, {"id": "e794dae6-8ee0-4bcb-ad36-b9c44c222e7f", "text": "Лимфаденит"}, {"id": "ed01131e-e37e-4d32-a92e-40ee0156a77e", "text": "Папиллярный рак почки"}, {"id": "406c1fe1-8266-410f-b3c6-973fa16564a5", "text": "Папиллома кожи"}], "created_at": "2026-11-19T17:51:28.58288+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}, {"id": "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d", "prompt": "Какой ТПП?", "options": [{"id": "14cfd792-4774-4394-a1ed-4f30ae1dd468", "text": "Воспаление"}, {"id": "f2dea413-8ed3-4d41-a922-293be38a200d", "text": "Опухоль"}, {"id": "22b8c237-4618-46dd-80d1-ebc4c2393681", "text": "Приспособление"}, {"id": "63079ea7-a66e-4f59-9ded-0e9a2dbcd12f", "text": "Нарушение кровообращения"}], "created_at": "2026-11-19T18:50:04.062365+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}, {"id": "886b3875-96f5-49e2-8f9b-256823c92515", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "da3be6e9-83c5-47ad-8c64-dd5f7f475b26", "text": "Вариант ответа 1"}, {"id": "b1f7ac4e-4551-4848-a2e1-d42a37d454a0", "text": "Вариант ответа 2"}, {"id": "b4815109-2d87-4005-9e6a-1ea04631d201", "text": "Вариант ответа 3"}, {"id": "4557c749-b07d-49c5-8344-ce9bf93aa4d5", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T20:23:10.922682+00:00", "image_path": "360:storage:41e81338-a044-492b-b615-f78ca01c0fdb"}, {"id": "2731f61d-078c-43be-843f-9c82c6505bcc", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "2fa81cb4-db4f-4803-b184-8d762c23cb30", "text": "Вариант ответа 1"}, {"id": "9f504a45-7409-4356-8871-0ddd8efe8555", "text": "Вариант ответа 2"}, {"id": "d4f5044e-f94c-44b5-839f-1081f68d7b1e", "text": "Вариант ответа 3"}, {"id": "00bf0558-e357-49e4-9779-a3d007a34b75", "text": "Вариант ответа 4"}], "created_at": "2026-11-21T20:42:35.075409+00:00", "image_path": "360:storage:426387d4-e6c1-40de-8b96-146233c5086a"}, {"id": "3c8cf418-8d80-477b-b431-ecb0d894486b", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "daa3cc4b-de16-4484-a354-069297e94a5c", "text": "Вариант ответа 1"}, {"id": "78d4fe78-d6aa-4de3-b709-04399f3d0ae9", "text": "Вариант ответа 2"}, {"id": "fa066726-5c57-4bd4-af52-892e2ba7e7e6", "text": "Вариант ответа 3"}, {"id": "b31e0669-ab25-40f0-b7b0-76086025d2b5", "text": "Вариант ответа 4"}], "created_at": "2026-11-20T00:37:13.071227+00:00", "image_path": "360:storage:68f4f4ca-412d-44ab-b86b-e3b6d10a4333"}, {"id": "3ff4a71b-dbe7-43cc-aed9-f4032c3f5912", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "1986638c-76b2-4d25-b0d6-23fc06da51e3", "text": "Вариант ответа 1"}, {"id": "a55d9ba4-acd9-4d30-9946-6ddae52fab24", "text": "Вариант ответа 2"}, {"id": "4d5caf12-0864-4fd8-b371-f63b77ca04a0", "text": "Вариант ответа 3"}, {"id": "a83bfe05-85ae-49c4-94c1-867bc74afdd9", "text": "Вариант ответа 4"}], "created_at": "2026-11-20T00:29:15.640366+00:00", "image_path": "360:storage:7c2aa764-945c-4f17-8874-c9407aa67a54"}, {"id": "a7a51068-6b31-40be-a10d-3cce26fee416", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "8a3f3572-0953-4599-9e98-cf48f408da06", "text": "Вариант ответа 1"}, {"id": "159027a3-5d4d-4e31-870c-57c19c042923", "text": "Вариант ответа 2"}, {"id": "c4d7068b-094b-4405-b284-1497ddc9085f", "text": "Вариант ответа 3"}, {"id": "eb8e51b9-9860-49ba-8400-4d096bc18272", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T20:33:07.011062+00:00", "image_path": "360:storage:ac0a0540-391b-4c47-a56f-75df0d53416d"}, {"id": "b384f160-6a8d-422c-abb8-dba32e3d78f9", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "d3e13b45-dad9-441c-860f-61c8160745e5", "text": "Вариант ответа 1"}, {"id": "22fa84a1-110c-4a9e-9af3-03fad983bbb9", "text": "Вариант ответа 2"}, {"id": "3ba99ae7-f025-47d3-b61f-3bfade562e57", "text": "Вариант ответа 3"}, {"id": "ee84e230-d213-435c-8ff8-f4e49ae25363", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T19:55:14.432145+00:00", "image_path": "360:storage:c3361ad1-0cf7-48a6-80eb-2f6010842e88"}], "t0": 1795296028564, "mode": "exam", "answers": {}, "savedAt": 1795296135178, "marathon": false, "taskOrder": [["2731f61d-078c-43be-843f-9c82c6505bcc"], ["b384f160-6a8d-422c-abb8-dba32e3d78f9"], ["886b3875-96f5-49e2-8f9b-256823c92515"], ["3ff4a71b-dbe7-43cc-aed9-f4032c3f5912"], ["3c8cf418-8d80-477b-b431-ecb0d894486b"], ["a7a51068-6b31-40be-a10d-3cce26fee416"], ["0922a960-a89d-4bde-b07e-6821a6cd42ad", "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d"]], "isMarathon": false, "optionOrder": {"2731f61d-078c-43be-843f-9c82c6505bcc": ["d4f5044e-f94c-44b5-839f-1081f68d7b1e", "9f504a45-7409-4356-8871-0ddd8efe8555", "00bf0558-e357-49e4-9779-a3d007a34b75", "2fa81cb4-db4f-4803-b184-8d762c23cb30"]}, "showAllNumbers": false}', E'2026-11-21 21:22:15.298991+00'),
  (E'79fb1d44-98ff-44b7-9213-d34b25fa4325', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'{"i": 0, "id": "79fb1d44-98ff-44b7-9213-d34b25fa4325", "qs": [{"id": "0922a960-a89d-4bde-b07e-6821a6cd42ad", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "3dafc49f-9595-4f06-ae0b-3f4a8ced50e3", "text": "Себорейный кератоз"}, {"id": "e794dae6-8ee0-4bcb-ad36-b9c44c222e7f", "text": "Лимфаденит"}, {"id": "ed01131e-e37e-4d32-a92e-40ee0156a77e", "text": "Папиллярный рак почки"}, {"id": "406c1fe1-8266-410f-b3c6-973fa16564a5", "text": "Папиллома кожи"}], "created_at": "2026-11-19T17:51:28.58288+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}, {"id": "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d", "prompt": "Какой ТПП?", "options": [{"id": "14cfd792-4774-4394-a1ed-4f30ae1dd468", "text": "Воспаление"}, {"id": "f2dea413-8ed3-4d41-a922-293be38a200d", "text": "Опухоль"}, {"id": "22b8c237-4618-46dd-80d1-ebc4c2393681", "text": "Приспособление"}, {"id": "63079ea7-a66e-4f59-9ded-0e9a2dbcd12f", "text": "Нарушение кровообращения"}], "created_at": "2026-11-19T18:50:04.062365+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}, {"id": "886b3875-96f5-49e2-8f9b-256823c92515", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "da3be6e9-83c5-47ad-8c64-dd5f7f475b26", "text": "Вариант ответа 1"}, {"id": "b1f7ac4e-4551-4848-a2e1-d42a37d454a0", "text": "Вариант ответа 2"}, {"id": "b4815109-2d87-4005-9e6a-1ea04631d201", "text": "Вариант ответа 3"}, {"id": "4557c749-b07d-49c5-8344-ce9bf93aa4d5", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T20:23:10.922682+00:00", "image_path": "360:storage:41e81338-a044-492b-b615-f78ca01c0fdb"}, {"id": "3c8cf418-8d80-477b-b431-ecb0d894486b", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "daa3cc4b-de16-4484-a354-069297e94a5c", "text": "Вариант ответа 1"}, {"id": "78d4fe78-d6aa-4de3-b709-04399f3d0ae9", "text": "Вариант ответа 2"}, {"id": "fa066726-5c57-4bd4-af52-892e2ba7e7e6", "text": "Вариант ответа 3"}, {"id": "b31e0669-ab25-40f0-b7b0-76086025d2b5", "text": "Вариант ответа 4"}], "created_at": "2026-11-20T00:37:13.071227+00:00", "image_path": "360:storage:68f4f4ca-412d-44ab-b86b-e3b6d10a4333"}, {"id": "3ff4a71b-dbe7-43cc-aed9-f4032c3f5912", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "1986638c-76b2-4d25-b0d6-23fc06da51e3", "text": "Вариант ответа 1"}, {"id": "a55d9ba4-acd9-4d30-9946-6ddae52fab24", "text": "Вариант ответа 2"}, {"id": "4d5caf12-0864-4fd8-b371-f63b77ca04a0", "text": "Вариант ответа 3"}, {"id": "a83bfe05-85ae-49c4-94c1-867bc74afdd9", "text": "Вариант ответа 4"}], "created_at": "2026-11-20T00:29:15.640366+00:00", "image_path": "360:storage:7c2aa764-945c-4f17-8874-c9407aa67a54"}, {"id": "a7a51068-6b31-40be-a10d-3cce26fee416", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "8a3f3572-0953-4599-9e98-cf48f408da06", "text": "Вариант ответа 1"}, {"id": "159027a3-5d4d-4e31-870c-57c19c042923", "text": "Вариант ответа 2"}, {"id": "c4d7068b-094b-4405-b284-1497ddc9085f", "text": "Вариант ответа 3"}, {"id": "eb8e51b9-9860-49ba-8400-4d096bc18272", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T20:33:07.011062+00:00", "image_path": "360:storage:ac0a0540-391b-4c47-a56f-75df0d53416d"}, {"id": "b384f160-6a8d-422c-abb8-dba32e3d78f9", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "d3e13b45-dad9-441c-860f-61c8160745e5", "text": "Вариант ответа 1"}, {"id": "22fa84a1-110c-4a9e-9af3-03fad983bbb9", "text": "Вариант ответа 2"}, {"id": "3ba99ae7-f025-47d3-b61f-3bfade562e57", "text": "Вариант ответа 3"}, {"id": "ee84e230-d213-435c-8ff8-f4e49ae25363", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T19:55:14.432145+00:00", "image_path": "360:storage:c3361ad1-0cf7-48a6-80eb-2f6010842e88"}], "t0": 1795287974439, "mode": "exam", "answers": {}, "savedAt": 1795287974439, "marathon": false, "taskOrder": [], "isMarathon": false, "optionOrder": {}, "showAllNumbers": false}', E'2026-11-21 19:06:14.400109+00'),
  (E'8bf0ef6f-1482-495c-8cc8-123bfd2e0fc8', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'{"i": 2, "id": "8bf0ef6f-1482-495c-8cc8-123bfd2e0fc8", "qs": [{"id": "0922a960-a89d-4bde-b07e-6821a6cd42ad", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "3dafc49f-9595-4f06-ae0b-3f4a8ced50e3", "text": "Себорейный кератоз"}, {"id": "e794dae6-8ee0-4bcb-ad36-b9c44c222e7f", "text": "Лимфаденит"}, {"id": "ed01131e-e37e-4d32-a92e-40ee0156a77e", "text": "Папиллярный рак почки"}, {"id": "406c1fe1-8266-410f-b3c6-973fa16564a5", "text": "Папиллома кожи"}], "created_at": "2026-11-19T17:51:28.58288+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}, {"id": "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d", "prompt": "Какой ТПП?", "options": [{"id": "14cfd792-4774-4394-a1ed-4f30ae1dd468", "text": "Воспаление"}, {"id": "f2dea413-8ed3-4d41-a922-293be38a200d", "text": "Опухоль"}, {"id": "22b8c237-4618-46dd-80d1-ebc4c2393681", "text": "Приспособление"}, {"id": "63079ea7-a66e-4f59-9ded-0e9a2dbcd12f", "text": "Нарушение кровообращения"}], "created_at": "2026-11-19T18:50:04.062365+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}, {"id": "886b3875-96f5-49e2-8f9b-256823c92515", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "da3be6e9-83c5-47ad-8c64-dd5f7f475b26", "text": "Вариант ответа 1"}, {"id": "b1f7ac4e-4551-4848-a2e1-d42a37d454a0", "text": "Вариант ответа 2"}, {"id": "b4815109-2d87-4005-9e6a-1ea04631d201", "text": "Вариант ответа 3"}, {"id": "4557c749-b07d-49c5-8344-ce9bf93aa4d5", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T20:23:10.922682+00:00", "image_path": "360:storage:41e81338-a044-492b-b615-f78ca01c0fdb"}, {"id": "2731f61d-078c-43be-843f-9c82c6505bcc", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "2fa81cb4-db4f-4803-b184-8d762c23cb30", "text": "Вариант ответа 1"}, {"id": "9f504a45-7409-4356-8871-0ddd8efe8555", "text": "Вариант ответа 2"}, {"id": "d4f5044e-f94c-44b5-839f-1081f68d7b1e", "text": "Вариант ответа 3"}, {"id": "00bf0558-e357-49e4-9779-a3d007a34b75", "text": "Вариант ответа 4"}], "created_at": "2026-11-21T20:42:35.075409+00:00", "image_path": "360:storage:426387d4-e6c1-40de-8b96-146233c5086a"}, {"id": "3c8cf418-8d80-477b-b431-ecb0d894486b", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "daa3cc4b-de16-4484-a354-069297e94a5c", "text": "Вариант ответа 1"}, {"id": "78d4fe78-d6aa-4de3-b709-04399f3d0ae9", "text": "Вариант ответа 2"}, {"id": "fa066726-5c57-4bd4-af52-892e2ba7e7e6", "text": "Вариант ответа 3"}, {"id": "b31e0669-ab25-40f0-b7b0-76086025d2b5", "text": "Вариант ответа 4"}], "created_at": "2026-11-20T00:37:13.071227+00:00", "image_path": "360:storage:68f4f4ca-412d-44ab-b86b-e3b6d10a4333"}, {"id": "51d27c6d-e223-4f2d-a2ad-4a65dc13c959", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "199bfcc9-fec2-49b9-b40f-ef51964ebb19", "text": "Вариант ответа 1"}, {"id": "47afa827-a1d8-426b-b699-b616a41bf0d5", "text": "Вариант ответа 2"}, {"id": "7134001a-75ce-4380-be2b-5806796c1973", "text": "Вариант ответа 3"}, {"id": "ab8fffe8-ec80-474c-877b-f7261811bef2", "text": "Вариант ответа 4"}], "created_at": "2026-11-21T21:58:10.78431+00:00", "image_path": "360:storage:76246477-3eb7-484b-9e74-5a727bf23646"}, {"id": "3ff4a71b-dbe7-43cc-aed9-f4032c3f5912", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "1986638c-76b2-4d25-b0d6-23fc06da51e3", "text": "Вариант ответа 1"}, {"id": "a55d9ba4-acd9-4d30-9946-6ddae52fab24", "text": "Вариант ответа 2"}, {"id": "4d5caf12-0864-4fd8-b371-f63b77ca04a0", "text": "Вариант ответа 3"}, {"id": "a83bfe05-85ae-49c4-94c1-867bc74afdd9", "text": "Вариант ответа 4"}], "created_at": "2026-11-20T00:29:15.640366+00:00", "image_path": "360:storage:7c2aa764-945c-4f17-8874-c9407aa67a54"}, {"id": "a7a51068-6b31-40be-a10d-3cce26fee416", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "8a3f3572-0953-4599-9e98-cf48f408da06", "text": "Вариант ответа 1"}, {"id": "159027a3-5d4d-4e31-870c-57c19c042923", "text": "Вариант ответа 2"}, {"id": "c4d7068b-094b-4405-b284-1497ddc9085f", "text": "Вариант ответа 3"}, {"id": "eb8e51b9-9860-49ba-8400-4d096bc18272", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T20:33:07.011062+00:00", "image_path": "360:storage:ac0a0540-391b-4c47-a56f-75df0d53416d"}, {"id": "b384f160-6a8d-422c-abb8-dba32e3d78f9", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "d3e13b45-dad9-441c-860f-61c8160745e5", "text": "Вариант ответа 1"}, {"id": "22fa84a1-110c-4a9e-9af3-03fad983bbb9", "text": "Вариант ответа 2"}, {"id": "3ba99ae7-f025-47d3-b61f-3bfade562e57", "text": "Вариант ответа 3"}, {"id": "ee84e230-d213-435c-8ff8-f4e49ae25363", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T19:55:14.432145+00:00", "image_path": "360:storage:c3361ad1-0cf7-48a6-80eb-2f6010842e88"}], "t0": 1795300348425, "mode": "exam", "answers": {}, "savedAt": 1795300773668, "marathon": false, "taskOrder": [["3ff4a71b-dbe7-43cc-aed9-f4032c3f5912"], ["b384f160-6a8d-422c-abb8-dba32e3d78f9"], ["0922a960-a89d-4bde-b07e-6821a6cd42ad", "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d"], ["2731f61d-078c-43be-843f-9c82c6505bcc"], ["a7a51068-6b31-40be-a10d-3cce26fee416"], ["3c8cf418-8d80-477b-b431-ecb0d894486b"], ["51d27c6d-e223-4f2d-a2ad-4a65dc13c959"], ["886b3875-96f5-49e2-8f9b-256823c92515"]], "isMarathon": false, "optionOrder": {"0922a960-a89d-4bde-b07e-6821a6cd42ad": ["406c1fe1-8266-410f-b3c6-973fa16564a5", "ed01131e-e37e-4d32-a92e-40ee0156a77e", "3dafc49f-9595-4f06-ae0b-3f4a8ced50e3", "e794dae6-8ee0-4bcb-ad36-b9c44c222e7f"], "3ff4a71b-dbe7-43cc-aed9-f4032c3f5912": ["a55d9ba4-acd9-4d30-9946-6ddae52fab24", "1986638c-76b2-4d25-b0d6-23fc06da51e3", "4d5caf12-0864-4fd8-b371-f63b77ca04a0", "a83bfe05-85ae-49c4-94c1-867bc74afdd9"], "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d": ["f2dea413-8ed3-4d41-a922-293be38a200d", "22b8c237-4618-46dd-80d1-ebc4c2393681", "63079ea7-a66e-4f59-9ded-0e9a2dbcd12f", "14cfd792-4774-4394-a1ed-4f30ae1dd468"], "b384f160-6a8d-422c-abb8-dba32e3d78f9": ["22fa84a1-110c-4a9e-9af3-03fad983bbb9", "ee84e230-d213-435c-8ff8-f4e49ae25363", "3ba99ae7-f025-47d3-b61f-3bfade562e57", "d3e13b45-dad9-441c-860f-61c8160745e5"]}, "showAllNumbers": false}', E'2026-11-21 22:39:33.706804+00'),
  (E'9bcf5a10-c722-4358-abcd-ece92aa0676f', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'{"i": 0, "id": "9bcf5a10-c722-4358-abcd-ece92aa0676f", "qs": [{"id": "62af2f62-fcac-48bf-8618-5c18d44125d4", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "2c4d8af2-5abd-49f3-b329-744d81a1c4d1", "text": "Вариант ответа 1"}, {"id": "6fbc983d-b23d-49da-8a42-9209903fe698", "text": "Вариант ответа 2"}, {"id": "01ecb5b4-e0b3-4181-9ac7-d2e7ecc79ad6", "text": "Вариант ответа 3"}, {"id": "5b772eb9-3883-4aae-8e75-045366005052", "text": "Вариант ответа 4"}], "created_at": "2026-11-21T22:39:58.467664+00:00", "image_path": "360:storage:4efcd4a8-c8e4-488a-955a-2cf97aae40f2"}], "t0": 1795300814295, "mode": "exam", "answers": {}, "savedAt": 1795301264217, "marathon": false, "taskOrder": [["62af2f62-fcac-48bf-8618-5c18d44125d4"]], "isMarathon": false, "optionOrder": {"62af2f62-fcac-48bf-8618-5c18d44125d4": ["6fbc983d-b23d-49da-8a42-9209903fe698", "01ecb5b4-e0b3-4181-9ac7-d2e7ecc79ad6", "5b772eb9-3883-4aae-8e75-045366005052", "2c4d8af2-5abd-49f3-b329-744d81a1c4d1"]}, "showAllNumbers": false}', E'2026-11-21 22:47:44.226614+00'),
  (E'e42f2d54-2082-44c1-ba71-0e834d55a38a', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'{"i": 3, "id": "e42f2d54-2082-44c1-ba71-0e834d55a38a", "qs": [{"id": "0922a960-a89d-4bde-b07e-6821a6cd42ad", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "3dafc49f-9595-4f06-ae0b-3f4a8ced50e3", "text": "Себорейный кератоз"}, {"id": "e794dae6-8ee0-4bcb-ad36-b9c44c222e7f", "text": "Лимфаденит"}, {"id": "ed01131e-e37e-4d32-a92e-40ee0156a77e", "text": "Папиллярный рак почки"}, {"id": "406c1fe1-8266-410f-b3c6-973fa16564a5", "text": "Папиллома кожи"}], "created_at": "2026-11-19T17:51:28.58288+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}, {"id": "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d", "prompt": "Какой ТПП?", "options": [{"id": "14cfd792-4774-4394-a1ed-4f30ae1dd468", "text": "Воспаление"}, {"id": "f2dea413-8ed3-4d41-a922-293be38a200d", "text": "Опухоль"}, {"id": "22b8c237-4618-46dd-80d1-ebc4c2393681", "text": "Приспособление"}, {"id": "63079ea7-a66e-4f59-9ded-0e9a2dbcd12f", "text": "Нарушение кровообращения"}], "created_at": "2026-11-19T18:50:04.062365+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}, {"id": "886b3875-96f5-49e2-8f9b-256823c92515", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "da3be6e9-83c5-47ad-8c64-dd5f7f475b26", "text": "Вариант ответа 1"}, {"id": "b1f7ac4e-4551-4848-a2e1-d42a37d454a0", "text": "Вариант ответа 2"}, {"id": "b4815109-2d87-4005-9e6a-1ea04631d201", "text": "Вариант ответа 3"}, {"id": "4557c749-b07d-49c5-8344-ce9bf93aa4d5", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T20:23:10.922682+00:00", "image_path": "360:storage:41e81338-a044-492b-b615-f78ca01c0fdb"}, {"id": "3c8cf418-8d80-477b-b431-ecb0d894486b", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "daa3cc4b-de16-4484-a354-069297e94a5c", "text": "Вариант ответа 1"}, {"id": "78d4fe78-d6aa-4de3-b709-04399f3d0ae9", "text": "Вариант ответа 2"}, {"id": "fa066726-5c57-4bd4-af52-892e2ba7e7e6", "text": "Вариант ответа 3"}, {"id": "b31e0669-ab25-40f0-b7b0-76086025d2b5", "text": "Вариант ответа 4"}], "created_at": "2026-11-20T00:37:13.071227+00:00", "image_path": "360:storage:68f4f4ca-412d-44ab-b86b-e3b6d10a4333"}, {"id": "3ff4a71b-dbe7-43cc-aed9-f4032c3f5912", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "1986638c-76b2-4d25-b0d6-23fc06da51e3", "text": "Вариант ответа 1"}, {"id": "a55d9ba4-acd9-4d30-9946-6ddae52fab24", "text": "Вариант ответа 2"}, {"id": "4d5caf12-0864-4fd8-b371-f63b77ca04a0", "text": "Вариант ответа 3"}, {"id": "a83bfe05-85ae-49c4-94c1-867bc74afdd9", "text": "Вариант ответа 4"}], "created_at": "2026-11-20T00:29:15.640366+00:00", "image_path": "360:storage:7c2aa764-945c-4f17-8874-c9407aa67a54"}, {"id": "a7a51068-6b31-40be-a10d-3cce26fee416", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "8a3f3572-0953-4599-9e98-cf48f408da06", "text": "Вариант ответа 1"}, {"id": "159027a3-5d4d-4e31-870c-57c19c042923", "text": "Вариант ответа 2"}, {"id": "c4d7068b-094b-4405-b284-1497ddc9085f", "text": "Вариант ответа 3"}, {"id": "eb8e51b9-9860-49ba-8400-4d096bc18272", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T20:33:07.011062+00:00", "image_path": "360:storage:ac0a0540-391b-4c47-a56f-75df0d53416d"}, {"id": "b384f160-6a8d-422c-abb8-dba32e3d78f9", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "d3e13b45-dad9-441c-860f-61c8160745e5", "text": "Вариант ответа 1"}, {"id": "22fa84a1-110c-4a9e-9af3-03fad983bbb9", "text": "Вариант ответа 2"}, {"id": "3ba99ae7-f025-47d3-b61f-3bfade562e57", "text": "Вариант ответа 3"}, {"id": "ee84e230-d213-435c-8ff8-f4e49ae25363", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T19:55:14.432145+00:00", "image_path": "360:storage:c3361ad1-0cf7-48a6-80eb-2f6010842e88"}], "t0": 1795287982347, "mode": "exam", "answers": {}, "savedAt": 1795288881916, "marathon": false, "taskOrder": [["3ff4a71b-dbe7-43cc-aed9-f4032c3f5912"], ["0922a960-a89d-4bde-b07e-6821a6cd42ad", "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d"], ["886b3875-96f5-49e2-8f9b-256823c92515"], ["a7a51068-6b31-40be-a10d-3cce26fee416"], ["b384f160-6a8d-422c-abb8-dba32e3d78f9"], ["3c8cf418-8d80-477b-b431-ecb0d894486b"]], "isMarathon": false, "optionOrder": {"0922a960-a89d-4bde-b07e-6821a6cd42ad": ["e794dae6-8ee0-4bcb-ad36-b9c44c222e7f", "406c1fe1-8266-410f-b3c6-973fa16564a5", "ed01131e-e37e-4d32-a92e-40ee0156a77e", "3dafc49f-9595-4f06-ae0b-3f4a8ced50e3"], "3ff4a71b-dbe7-43cc-aed9-f4032c3f5912": ["a55d9ba4-acd9-4d30-9946-6ddae52fab24", "1986638c-76b2-4d25-b0d6-23fc06da51e3", "4d5caf12-0864-4fd8-b371-f63b77ca04a0", "a83bfe05-85ae-49c4-94c1-867bc74afdd9"], "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d": ["63079ea7-a66e-4f59-9ded-0e9a2dbcd12f", "f2dea413-8ed3-4d41-a922-293be38a200d", "14cfd792-4774-4394-a1ed-4f30ae1dd468", "22b8c237-4618-46dd-80d1-ebc4c2393681"], "886b3875-96f5-49e2-8f9b-256823c92515": ["da3be6e9-83c5-47ad-8c64-dd5f7f475b26", "b4815109-2d87-4005-9e6a-1ea04631d201", "b1f7ac4e-4551-4848-a2e1-d42a37d454a0", "4557c749-b07d-49c5-8344-ce9bf93aa4d5"]}, "showAllNumbers": false}', E'2026-11-21 19:21:21.949323+00'),
  (E'76c27182-6425-4852-b9a9-e499ecbc6e23', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'{"i": 5, "id": "76c27182-6425-4852-b9a9-e499ecbc6e23", "qs": [{"id": "0922a960-a89d-4bde-b07e-6821a6cd42ad", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "3dafc49f-9595-4f06-ae0b-3f4a8ced50e3", "text": "Себорейный кератоз"}, {"id": "e794dae6-8ee0-4bcb-ad36-b9c44c222e7f", "text": "Лимфаденит"}, {"id": "ed01131e-e37e-4d32-a92e-40ee0156a77e", "text": "Папиллярный рак почки"}, {"id": "406c1fe1-8266-410f-b3c6-973fa16564a5", "text": "Папиллома кожи"}], "created_at": "2026-11-19T17:51:28.58288+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}, {"id": "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d", "prompt": "Какой ТПП?", "options": [{"id": "14cfd792-4774-4394-a1ed-4f30ae1dd468", "text": "Воспаление"}, {"id": "f2dea413-8ed3-4d41-a922-293be38a200d", "text": "Опухоль"}, {"id": "22b8c237-4618-46dd-80d1-ebc4c2393681", "text": "Приспособление"}, {"id": "63079ea7-a66e-4f59-9ded-0e9a2dbcd12f", "text": "Нарушение кровообращения"}], "created_at": "2026-11-19T18:50:04.062365+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}, {"id": "886b3875-96f5-49e2-8f9b-256823c92515", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "da3be6e9-83c5-47ad-8c64-dd5f7f475b26", "text": "Вариант ответа 1"}, {"id": "b1f7ac4e-4551-4848-a2e1-d42a37d454a0", "text": "Вариант ответа 2"}, {"id": "b4815109-2d87-4005-9e6a-1ea04631d201", "text": "Вариант ответа 3"}, {"id": "4557c749-b07d-49c5-8344-ce9bf93aa4d5", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T20:23:10.922682+00:00", "image_path": "360:storage:41e81338-a044-492b-b615-f78ca01c0fdb"}, {"id": "3c8cf418-8d80-477b-b431-ecb0d894486b", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "daa3cc4b-de16-4484-a354-069297e94a5c", "text": "Вариант ответа 1"}, {"id": "78d4fe78-d6aa-4de3-b709-04399f3d0ae9", "text": "Вариант ответа 2"}, {"id": "fa066726-5c57-4bd4-af52-892e2ba7e7e6", "text": "Вариант ответа 3"}, {"id": "b31e0669-ab25-40f0-b7b0-76086025d2b5", "text": "Вариант ответа 4"}], "created_at": "2026-11-20T00:37:13.071227+00:00", "image_path": "360:storage:68f4f4ca-412d-44ab-b86b-e3b6d10a4333"}, {"id": "3ff4a71b-dbe7-43cc-aed9-f4032c3f5912", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "1986638c-76b2-4d25-b0d6-23fc06da51e3", "text": "Вариант ответа 1"}, {"id": "a55d9ba4-acd9-4d30-9946-6ddae52fab24", "text": "Вариант ответа 2"}, {"id": "4d5caf12-0864-4fd8-b371-f63b77ca04a0", "text": "Вариант ответа 3"}, {"id": "a83bfe05-85ae-49c4-94c1-867bc74afdd9", "text": "Вариант ответа 4"}], "created_at": "2026-11-20T00:29:15.640366+00:00", "image_path": "360:storage:7c2aa764-945c-4f17-8874-c9407aa67a54"}, {"id": "a7a51068-6b31-40be-a10d-3cce26fee416", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "8a3f3572-0953-4599-9e98-cf48f408da06", "text": "Вариант ответа 1"}, {"id": "159027a3-5d4d-4e31-870c-57c19c042923", "text": "Вариант ответа 2"}, {"id": "c4d7068b-094b-4405-b284-1497ddc9085f", "text": "Вариант ответа 3"}, {"id": "eb8e51b9-9860-49ba-8400-4d096bc18272", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T20:33:07.011062+00:00", "image_path": "360:storage:ac0a0540-391b-4c47-a56f-75df0d53416d"}, {"id": "b384f160-6a8d-422c-abb8-dba32e3d78f9", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "d3e13b45-dad9-441c-860f-61c8160745e5", "text": "Вариант ответа 1"}, {"id": "22fa84a1-110c-4a9e-9af3-03fad983bbb9", "text": "Вариант ответа 2"}, {"id": "3ba99ae7-f025-47d3-b61f-3bfade562e57", "text": "Вариант ответа 3"}, {"id": "ee84e230-d213-435c-8ff8-f4e49ae25363", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T19:55:14.432145+00:00", "image_path": "360:storage:c3361ad1-0cf7-48a6-80eb-2f6010842e88"}], "t0": 1795288888513, "mode": "exam", "answers": {}, "savedAt": 1795288893904, "marathon": false, "taskOrder": [["0922a960-a89d-4bde-b07e-6821a6cd42ad", "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d"], ["886b3875-96f5-49e2-8f9b-256823c92515"], ["a7a51068-6b31-40be-a10d-3cce26fee416"], ["3ff4a71b-dbe7-43cc-aed9-f4032c3f5912"], ["3c8cf418-8d80-477b-b431-ecb0d894486b"], ["b384f160-6a8d-422c-abb8-dba32e3d78f9"]], "isMarathon": false, "optionOrder": {"0922a960-a89d-4bde-b07e-6821a6cd42ad": ["ed01131e-e37e-4d32-a92e-40ee0156a77e", "3dafc49f-9595-4f06-ae0b-3f4a8ced50e3", "e794dae6-8ee0-4bcb-ad36-b9c44c222e7f", "406c1fe1-8266-410f-b3c6-973fa16564a5"], "3ff4a71b-dbe7-43cc-aed9-f4032c3f5912": ["a83bfe05-85ae-49c4-94c1-867bc74afdd9", "4d5caf12-0864-4fd8-b371-f63b77ca04a0", "1986638c-76b2-4d25-b0d6-23fc06da51e3", "a55d9ba4-acd9-4d30-9946-6ddae52fab24"], "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d": ["22b8c237-4618-46dd-80d1-ebc4c2393681", "63079ea7-a66e-4f59-9ded-0e9a2dbcd12f", "14cfd792-4774-4394-a1ed-4f30ae1dd468", "f2dea413-8ed3-4d41-a922-293be38a200d"], "886b3875-96f5-49e2-8f9b-256823c92515": ["4557c749-b07d-49c5-8344-ce9bf93aa4d5", "b1f7ac4e-4551-4848-a2e1-d42a37d454a0", "b4815109-2d87-4005-9e6a-1ea04631d201", "da3be6e9-83c5-47ad-8c64-dd5f7f475b26"], "a7a51068-6b31-40be-a10d-3cce26fee416": ["8a3f3572-0953-4599-9e98-cf48f408da06", "c4d7068b-094b-4405-b284-1497ddc9085f", "eb8e51b9-9860-49ba-8400-4d096bc18272", "159027a3-5d4d-4e31-870c-57c19c042923"]}, "showAllNumbers": false}', E'2026-11-21 19:21:33.876893+00'),
  (E'1775a8e2-78c5-4ec9-9443-98a2067d79d0', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'{"i": 5, "id": "1775a8e2-78c5-4ec9-9443-98a2067d79d0", "qs": [{"id": "0922a960-a89d-4bde-b07e-6821a6cd42ad", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "3dafc49f-9595-4f06-ae0b-3f4a8ced50e3", "text": "Себорейный кератоз"}, {"id": "e794dae6-8ee0-4bcb-ad36-b9c44c222e7f", "text": "Лимфаденит"}, {"id": "ed01131e-e37e-4d32-a92e-40ee0156a77e", "text": "Папиллярный рак почки"}, {"id": "406c1fe1-8266-410f-b3c6-973fa16564a5", "text": "Папиллома кожи"}], "created_at": "2026-11-19T17:51:28.58288+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}, {"id": "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d", "prompt": "Какой ТПП?", "options": [{"id": "14cfd792-4774-4394-a1ed-4f30ae1dd468", "text": "Воспаление"}, {"id": "f2dea413-8ed3-4d41-a922-293be38a200d", "text": "Опухоль"}, {"id": "22b8c237-4618-46dd-80d1-ebc4c2393681", "text": "Приспособление"}, {"id": "63079ea7-a66e-4f59-9ded-0e9a2dbcd12f", "text": "Нарушение кровообращения"}], "created_at": "2026-11-19T18:50:04.062365+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}, {"id": "886b3875-96f5-49e2-8f9b-256823c92515", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "da3be6e9-83c5-47ad-8c64-dd5f7f475b26", "text": "Вариант ответа 1"}, {"id": "b1f7ac4e-4551-4848-a2e1-d42a37d454a0", "text": "Вариант ответа 2"}, {"id": "b4815109-2d87-4005-9e6a-1ea04631d201", "text": "Вариант ответа 3"}, {"id": "4557c749-b07d-49c5-8344-ce9bf93aa4d5", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T20:23:10.922682+00:00", "image_path": "360:storage:41e81338-a044-492b-b615-f78ca01c0fdb"}, {"id": "3c8cf418-8d80-477b-b431-ecb0d894486b", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "daa3cc4b-de16-4484-a354-069297e94a5c", "text": "Вариант ответа 1"}, {"id": "78d4fe78-d6aa-4de3-b709-04399f3d0ae9", "text": "Вариант ответа 2"}, {"id": "fa066726-5c57-4bd4-af52-892e2ba7e7e6", "text": "Вариант ответа 3"}, {"id": "b31e0669-ab25-40f0-b7b0-76086025d2b5", "text": "Вариант ответа 4"}], "created_at": "2026-11-20T00:37:13.071227+00:00", "image_path": "360:storage:68f4f4ca-412d-44ab-b86b-e3b6d10a4333"}, {"id": "3ff4a71b-dbe7-43cc-aed9-f4032c3f5912", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "1986638c-76b2-4d25-b0d6-23fc06da51e3", "text": "Вариант ответа 1"}, {"id": "a55d9ba4-acd9-4d30-9946-6ddae52fab24", "text": "Вариант ответа 2"}, {"id": "4d5caf12-0864-4fd8-b371-f63b77ca04a0", "text": "Вариант ответа 3"}, {"id": "a83bfe05-85ae-49c4-94c1-867bc74afdd9", "text": "Вариант ответа 4"}], "created_at": "2026-11-20T00:29:15.640366+00:00", "image_path": "360:storage:7c2aa764-945c-4f17-8874-c9407aa67a54"}, {"id": "a7a51068-6b31-40be-a10d-3cce26fee416", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "8a3f3572-0953-4599-9e98-cf48f408da06", "text": "Вариант ответа 1"}, {"id": "159027a3-5d4d-4e31-870c-57c19c042923", "text": "Вариант ответа 2"}, {"id": "c4d7068b-094b-4405-b284-1497ddc9085f", "text": "Вариант ответа 3"}, {"id": "eb8e51b9-9860-49ba-8400-4d096bc18272", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T20:33:07.011062+00:00", "image_path": "360:storage:ac0a0540-391b-4c47-a56f-75df0d53416d"}, {"id": "b384f160-6a8d-422c-abb8-dba32e3d78f9", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "d3e13b45-dad9-441c-860f-61c8160745e5", "text": "Вариант ответа 1"}, {"id": "22fa84a1-110c-4a9e-9af3-03fad983bbb9", "text": "Вариант ответа 2"}, {"id": "3ba99ae7-f025-47d3-b61f-3bfade562e57", "text": "Вариант ответа 3"}, {"id": "ee84e230-d213-435c-8ff8-f4e49ae25363", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T19:55:14.432145+00:00", "image_path": "360:storage:c3361ad1-0cf7-48a6-80eb-2f6010842e88"}], "t0": 1795288899578, "mode": "exam", "answers": {}, "savedAt": 1795289119925, "marathon": false, "taskOrder": [["886b3875-96f5-49e2-8f9b-256823c92515"], ["b384f160-6a8d-422c-abb8-dba32e3d78f9"], ["3ff4a71b-dbe7-43cc-aed9-f4032c3f5912"], ["0922a960-a89d-4bde-b07e-6821a6cd42ad", "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d"], ["3c8cf418-8d80-477b-b431-ecb0d894486b"], ["a7a51068-6b31-40be-a10d-3cce26fee416"]], "isMarathon": false, "optionOrder": {"0922a960-a89d-4bde-b07e-6821a6cd42ad": ["3dafc49f-9595-4f06-ae0b-3f4a8ced50e3", "e794dae6-8ee0-4bcb-ad36-b9c44c222e7f", "406c1fe1-8266-410f-b3c6-973fa16564a5", "ed01131e-e37e-4d32-a92e-40ee0156a77e"], "3c8cf418-8d80-477b-b431-ecb0d894486b": ["b31e0669-ab25-40f0-b7b0-76086025d2b5", "78d4fe78-d6aa-4de3-b709-04399f3d0ae9", "daa3cc4b-de16-4484-a354-069297e94a5c", "fa066726-5c57-4bd4-af52-892e2ba7e7e6"], "3ff4a71b-dbe7-43cc-aed9-f4032c3f5912": ["4d5caf12-0864-4fd8-b371-f63b77ca04a0", "a55d9ba4-acd9-4d30-9946-6ddae52fab24", "a83bfe05-85ae-49c4-94c1-867bc74afdd9", "1986638c-76b2-4d25-b0d6-23fc06da51e3"], "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d": ["22b8c237-4618-46dd-80d1-ebc4c2393681", "14cfd792-4774-4394-a1ed-4f30ae1dd468", "63079ea7-a66e-4f59-9ded-0e9a2dbcd12f", "f2dea413-8ed3-4d41-a922-293be38a200d"], "886b3875-96f5-49e2-8f9b-256823c92515": ["4557c749-b07d-49c5-8344-ce9bf93aa4d5", "da3be6e9-83c5-47ad-8c64-dd5f7f475b26", "b4815109-2d87-4005-9e6a-1ea04631d201", "b1f7ac4e-4551-4848-a2e1-d42a37d454a0"], "a7a51068-6b31-40be-a10d-3cce26fee416": ["eb8e51b9-9860-49ba-8400-4d096bc18272", "c4d7068b-094b-4405-b284-1497ddc9085f", "159027a3-5d4d-4e31-870c-57c19c042923", "8a3f3572-0953-4599-9e98-cf48f408da06"], "b384f160-6a8d-422c-abb8-dba32e3d78f9": ["22fa84a1-110c-4a9e-9af3-03fad983bbb9", "3ba99ae7-f025-47d3-b61f-3bfade562e57", "ee84e230-d213-435c-8ff8-f4e49ae25363", "d3e13b45-dad9-441c-860f-61c8160745e5"]}, "showAllNumbers": false}', E'2026-11-21 19:25:19.934914+00'),
  (E'68e92580-e2ca-40f4-883d-a7f51fefc606', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'{"i": 0, "id": "68e92580-e2ca-40f4-883d-a7f51fefc606", "qs": [{"id": "7e04afcf-11c4-4fce-a076-f0e6c38903dc", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "33acdbea-ce31-44b6-84f4-e0c2ff169a3f", "text": "Вариант ответа 1"}, {"id": "3bd80f1a-4836-4b43-a035-2dc65923d7d8", "text": "Вариант ответа 2"}, {"id": "6caeb4f5-176c-4fb9-a326-5bae6cd7599e", "text": "Вариант ответа 3"}, {"id": "9995ae5a-b74f-4c01-8ae1-e57f42b6c33b", "text": "Вариант ответа 4"}], "created_at": "2026-11-21T22:50:33.456955+00:00", "image_path": "360:storage:46c6dda2-ea5e-4540-a329-3e2e1ec88ad3"}, {"id": "62af2f62-fcac-48bf-8618-5c18d44125d4", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "2c4d8af2-5abd-49f3-b329-744d81a1c4d1", "text": "Вариант ответа 1"}, {"id": "6fbc983d-b23d-49da-8a42-9209903fe698", "text": "Вариант ответа 2"}, {"id": "01ecb5b4-e0b3-4181-9ac7-d2e7ecc79ad6", "text": "Вариант ответа 3"}, {"id": "5b772eb9-3883-4aae-8e75-045366005052", "text": "Вариант ответа 4"}], "created_at": "2026-11-21T22:39:58.467664+00:00", "image_path": "360:storage:4efcd4a8-c8e4-488a-955a-2cf97aae40f2"}, {"id": "c7a7cb27-38d6-45a3-8650-52dfa395a233", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "218a7943-188a-4245-b828-f2a07a0f8bf4", "text": "Вариант ответа 1"}, {"id": "88992732-ce97-4a89-a4a7-d8dfa1371f90", "text": "Вариант ответа 2"}, {"id": "fa528847-2f5a-40c9-bc98-9aaa4d9510d1", "text": "Вариант ответа 3"}, {"id": "cbdefd83-96ad-4876-be26-f4d5d280ed3f", "text": "Вариант ответа 4"}], "created_at": "2026-11-21T22:43:25.384869+00:00", "image_path": "360:storage:5d0e5d32-e2ac-4717-a802-fea5d41bae26"}, {"id": "9a29bd7c-180d-4661-9224-4f3a788ffc07", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "cbf84e9b-178f-46eb-b171-988727c4487f", "text": "Вариант ответа 1"}, {"id": "69a6fdf4-3e58-4845-b121-34e2af3ff8eb", "text": "Вариант ответа 2"}, {"id": "33620ded-9b64-4384-a582-e1ec7d73f693", "text": "Вариант ответа 3"}, {"id": "b287b4d4-687e-4ad4-acf5-1b925ea7d765", "text": "Вариант ответа 4"}], "created_at": "2026-11-21T22:54:53.528719+00:00", "image_path": "360:storage:77a75e99-8785-47a0-9832-de1dc5c4087c"}], "t0": 1795302224688, "mode": "exam", "answers": {}, "savedAt": 1795302258780, "marathon": false, "taskOrder": [["62af2f62-fcac-48bf-8618-5c18d44125d4"], ["7e04afcf-11c4-4fce-a076-f0e6c38903dc"], ["c7a7cb27-38d6-45a3-8650-52dfa395a233"], ["9a29bd7c-180d-4661-9224-4f3a788ffc07"]], "isMarathon": false, "optionOrder": {"62af2f62-fcac-48bf-8618-5c18d44125d4": ["2c4d8af2-5abd-49f3-b329-744d81a1c4d1", "6fbc983d-b23d-49da-8a42-9209903fe698", "01ecb5b4-e0b3-4181-9ac7-d2e7ecc79ad6", "5b772eb9-3883-4aae-8e75-045366005052"], "7e04afcf-11c4-4fce-a076-f0e6c38903dc": ["3bd80f1a-4836-4b43-a035-2dc65923d7d8", "33acdbea-ce31-44b6-84f4-e0c2ff169a3f", "9995ae5a-b74f-4c01-8ae1-e57f42b6c33b", "6caeb4f5-176c-4fb9-a326-5bae6cd7599e"], "9a29bd7c-180d-4661-9224-4f3a788ffc07": ["69a6fdf4-3e58-4845-b121-34e2af3ff8eb", "cbf84e9b-178f-46eb-b171-988727c4487f", "b287b4d4-687e-4ad4-acf5-1b925ea7d765", "33620ded-9b64-4384-a582-e1ec7d73f693"], "c7a7cb27-38d6-45a3-8650-52dfa395a233": ["218a7943-188a-4245-b828-f2a07a0f8bf4", "cbdefd83-96ad-4876-be26-f4d5d280ed3f", "fa528847-2f5a-40c9-bc98-9aaa4d9510d1", "88992732-ce97-4a89-a4a7-d8dfa1371f90"]}, "showAllNumbers": false}', E'2026-11-21 23:04:18.82308+00'),
  (E'03a064bf-ba0b-4595-abaf-833244071dca', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'{"i": 3, "id": "03a064bf-ba0b-4595-abaf-833244071dca", "qs": [{"id": "0922a960-a89d-4bde-b07e-6821a6cd42ad", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "3dafc49f-9595-4f06-ae0b-3f4a8ced50e3", "text": "Себорейный кератоз"}, {"id": "e794dae6-8ee0-4bcb-ad36-b9c44c222e7f", "text": "Лимфаденит"}, {"id": "ed01131e-e37e-4d32-a92e-40ee0156a77e", "text": "Папиллярный рак почки"}, {"id": "406c1fe1-8266-410f-b3c6-973fa16564a5", "text": "Папиллома кожи"}], "created_at": "2026-11-19T17:51:28.58288+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}, {"id": "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d", "prompt": "Какой ТПП?", "options": [{"id": "14cfd792-4774-4394-a1ed-4f30ae1dd468", "text": "Воспаление"}, {"id": "f2dea413-8ed3-4d41-a922-293be38a200d", "text": "Опухоль"}, {"id": "22b8c237-4618-46dd-80d1-ebc4c2393681", "text": "Приспособление"}, {"id": "63079ea7-a66e-4f59-9ded-0e9a2dbcd12f", "text": "Нарушение кровообращения"}], "created_at": "2026-11-19T18:50:04.062365+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}, {"id": "886b3875-96f5-49e2-8f9b-256823c92515", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "da3be6e9-83c5-47ad-8c64-dd5f7f475b26", "text": "Вариант ответа 1"}, {"id": "b1f7ac4e-4551-4848-a2e1-d42a37d454a0", "text": "Вариант ответа 2"}, {"id": "b4815109-2d87-4005-9e6a-1ea04631d201", "text": "Вариант ответа 3"}, {"id": "4557c749-b07d-49c5-8344-ce9bf93aa4d5", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T20:23:10.922682+00:00", "image_path": "360:storage:41e81338-a044-492b-b615-f78ca01c0fdb"}, {"id": "3c8cf418-8d80-477b-b431-ecb0d894486b", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "daa3cc4b-de16-4484-a354-069297e94a5c", "text": "Вариант ответа 1"}, {"id": "78d4fe78-d6aa-4de3-b709-04399f3d0ae9", "text": "Вариант ответа 2"}, {"id": "fa066726-5c57-4bd4-af52-892e2ba7e7e6", "text": "Вариант ответа 3"}, {"id": "b31e0669-ab25-40f0-b7b0-76086025d2b5", "text": "Вариант ответа 4"}], "created_at": "2026-11-20T00:37:13.071227+00:00", "image_path": "360:storage:68f4f4ca-412d-44ab-b86b-e3b6d10a4333"}, {"id": "3ff4a71b-dbe7-43cc-aed9-f4032c3f5912", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "1986638c-76b2-4d25-b0d6-23fc06da51e3", "text": "Вариант ответа 1"}, {"id": "a55d9ba4-acd9-4d30-9946-6ddae52fab24", "text": "Вариант ответа 2"}, {"id": "4d5caf12-0864-4fd8-b371-f63b77ca04a0", "text": "Вариант ответа 3"}, {"id": "a83bfe05-85ae-49c4-94c1-867bc74afdd9", "text": "Вариант ответа 4"}], "created_at": "2026-11-20T00:29:15.640366+00:00", "image_path": "360:storage:7c2aa764-945c-4f17-8874-c9407aa67a54"}, {"id": "a7a51068-6b31-40be-a10d-3cce26fee416", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "8a3f3572-0953-4599-9e98-cf48f408da06", "text": "Вариант ответа 1"}, {"id": "159027a3-5d4d-4e31-870c-57c19c042923", "text": "Вариант ответа 2"}, {"id": "c4d7068b-094b-4405-b284-1497ddc9085f", "text": "Вариант ответа 3"}, {"id": "eb8e51b9-9860-49ba-8400-4d096bc18272", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T20:33:07.011062+00:00", "image_path": "360:storage:ac0a0540-391b-4c47-a56f-75df0d53416d"}, {"id": "b384f160-6a8d-422c-abb8-dba32e3d78f9", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "d3e13b45-dad9-441c-860f-61c8160745e5", "text": "Вариант ответа 1"}, {"id": "22fa84a1-110c-4a9e-9af3-03fad983bbb9", "text": "Вариант ответа 2"}, {"id": "3ba99ae7-f025-47d3-b61f-3bfade562e57", "text": "Вариант ответа 3"}, {"id": "ee84e230-d213-435c-8ff8-f4e49ae25363", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T19:55:14.432145+00:00", "image_path": "360:storage:c3361ad1-0cf7-48a6-80eb-2f6010842e88"}], "t0": 1795292918261, "mode": "exam", "answers": {}, "savedAt": 1795292980887, "marathon": false, "taskOrder": [["3c8cf418-8d80-477b-b431-ecb0d894486b"], ["3ff4a71b-dbe7-43cc-aed9-f4032c3f5912"], ["0922a960-a89d-4bde-b07e-6821a6cd42ad", "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d"], ["886b3875-96f5-49e2-8f9b-256823c92515"], ["b384f160-6a8d-422c-abb8-dba32e3d78f9"], ["a7a51068-6b31-40be-a10d-3cce26fee416"]], "isMarathon": false, "optionOrder": {"0922a960-a89d-4bde-b07e-6821a6cd42ad": ["e794dae6-8ee0-4bcb-ad36-b9c44c222e7f", "3dafc49f-9595-4f06-ae0b-3f4a8ced50e3", "ed01131e-e37e-4d32-a92e-40ee0156a77e", "406c1fe1-8266-410f-b3c6-973fa16564a5"], "3c8cf418-8d80-477b-b431-ecb0d894486b": ["daa3cc4b-de16-4484-a354-069297e94a5c", "fa066726-5c57-4bd4-af52-892e2ba7e7e6", "78d4fe78-d6aa-4de3-b709-04399f3d0ae9", "b31e0669-ab25-40f0-b7b0-76086025d2b5"], "3ff4a71b-dbe7-43cc-aed9-f4032c3f5912": ["a83bfe05-85ae-49c4-94c1-867bc74afdd9", "4d5caf12-0864-4fd8-b371-f63b77ca04a0", "1986638c-76b2-4d25-b0d6-23fc06da51e3", "a55d9ba4-acd9-4d30-9946-6ddae52fab24"], "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d": ["63079ea7-a66e-4f59-9ded-0e9a2dbcd12f", "22b8c237-4618-46dd-80d1-ebc4c2393681", "f2dea413-8ed3-4d41-a922-293be38a200d", "14cfd792-4774-4394-a1ed-4f30ae1dd468"], "886b3875-96f5-49e2-8f9b-256823c92515": ["4557c749-b07d-49c5-8344-ce9bf93aa4d5", "b1f7ac4e-4551-4848-a2e1-d42a37d454a0", "b4815109-2d87-4005-9e6a-1ea04631d201", "da3be6e9-83c5-47ad-8c64-dd5f7f475b26"]}, "showAllNumbers": false}', E'2026-11-21 20:29:41.155366+00'),
  (E'e51653b4-2920-4851-bfa1-69e4067ef090', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'{"i": 0, "id": "e51653b4-2920-4851-bfa1-69e4067ef090", "qs": [{"id": "0922a960-a89d-4bde-b07e-6821a6cd42ad", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "3dafc49f-9595-4f06-ae0b-3f4a8ced50e3", "text": "Себорейный кератоз"}, {"id": "e794dae6-8ee0-4bcb-ad36-b9c44c222e7f", "text": "Лимфаденит"}, {"id": "ed01131e-e37e-4d32-a92e-40ee0156a77e", "text": "Папиллярный рак почки"}, {"id": "406c1fe1-8266-410f-b3c6-973fa16564a5", "text": "Папиллома кожи"}], "created_at": "2026-11-19T17:51:28.58288+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}, {"id": "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d", "prompt": "Какой ТПП?", "options": [{"id": "14cfd792-4774-4394-a1ed-4f30ae1dd468", "text": "Воспаление"}, {"id": "f2dea413-8ed3-4d41-a922-293be38a200d", "text": "Опухоль"}, {"id": "22b8c237-4618-46dd-80d1-ebc4c2393681", "text": "Приспособление"}, {"id": "63079ea7-a66e-4f59-9ded-0e9a2dbcd12f", "text": "Нарушение кровообращения"}], "created_at": "2026-11-19T18:50:04.062365+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}, {"id": "886b3875-96f5-49e2-8f9b-256823c92515", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "da3be6e9-83c5-47ad-8c64-dd5f7f475b26", "text": "Вариант ответа 1"}, {"id": "b1f7ac4e-4551-4848-a2e1-d42a37d454a0", "text": "Вариант ответа 2"}, {"id": "b4815109-2d87-4005-9e6a-1ea04631d201", "text": "Вариант ответа 3"}, {"id": "4557c749-b07d-49c5-8344-ce9bf93aa4d5", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T20:23:10.922682+00:00", "image_path": "360:storage:41e81338-a044-492b-b615-f78ca01c0fdb"}, {"id": "3c8cf418-8d80-477b-b431-ecb0d894486b", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "daa3cc4b-de16-4484-a354-069297e94a5c", "text": "Вариант ответа 1"}, {"id": "78d4fe78-d6aa-4de3-b709-04399f3d0ae9", "text": "Вариант ответа 2"}, {"id": "fa066726-5c57-4bd4-af52-892e2ba7e7e6", "text": "Вариант ответа 3"}, {"id": "b31e0669-ab25-40f0-b7b0-76086025d2b5", "text": "Вариант ответа 4"}], "created_at": "2026-11-20T00:37:13.071227+00:00", "image_path": "360:storage:68f4f4ca-412d-44ab-b86b-e3b6d10a4333"}, {"id": "3ff4a71b-dbe7-43cc-aed9-f4032c3f5912", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "1986638c-76b2-4d25-b0d6-23fc06da51e3", "text": "Вариант ответа 1"}, {"id": "a55d9ba4-acd9-4d30-9946-6ddae52fab24", "text": "Вариант ответа 2"}, {"id": "4d5caf12-0864-4fd8-b371-f63b77ca04a0", "text": "Вариант ответа 3"}, {"id": "a83bfe05-85ae-49c4-94c1-867bc74afdd9", "text": "Вариант ответа 4"}], "created_at": "2026-11-20T00:29:15.640366+00:00", "image_path": "360:storage:7c2aa764-945c-4f17-8874-c9407aa67a54"}, {"id": "a7a51068-6b31-40be-a10d-3cce26fee416", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "8a3f3572-0953-4599-9e98-cf48f408da06", "text": "Вариант ответа 1"}, {"id": "159027a3-5d4d-4e31-870c-57c19c042923", "text": "Вариант ответа 2"}, {"id": "c4d7068b-094b-4405-b284-1497ddc9085f", "text": "Вариант ответа 3"}, {"id": "eb8e51b9-9860-49ba-8400-4d096bc18272", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T20:33:07.011062+00:00", "image_path": "360:storage:ac0a0540-391b-4c47-a56f-75df0d53416d"}, {"id": "b384f160-6a8d-422c-abb8-dba32e3d78f9", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "d3e13b45-dad9-441c-860f-61c8160745e5", "text": "Вариант ответа 1"}, {"id": "22fa84a1-110c-4a9e-9af3-03fad983bbb9", "text": "Вариант ответа 2"}, {"id": "3ba99ae7-f025-47d3-b61f-3bfade562e57", "text": "Вариант ответа 3"}, {"id": "ee84e230-d213-435c-8ff8-f4e49ae25363", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T19:55:14.432145+00:00", "image_path": "360:storage:c3361ad1-0cf7-48a6-80eb-2f6010842e88"}], "t0": 1795293458150, "mode": "exam", "answers": {}, "savedAt": 1795293571504, "marathon": false, "taskOrder": [["a7a51068-6b31-40be-a10d-3cce26fee416"], ["b384f160-6a8d-422c-abb8-dba32e3d78f9"], ["0922a960-a89d-4bde-b07e-6821a6cd42ad", "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d"], ["3ff4a71b-dbe7-43cc-aed9-f4032c3f5912"], ["886b3875-96f5-49e2-8f9b-256823c92515"], ["3c8cf418-8d80-477b-b431-ecb0d894486b"]], "isMarathon": false, "optionOrder": {"a7a51068-6b31-40be-a10d-3cce26fee416": ["8a3f3572-0953-4599-9e98-cf48f408da06", "eb8e51b9-9860-49ba-8400-4d096bc18272", "159027a3-5d4d-4e31-870c-57c19c042923", "c4d7068b-094b-4405-b284-1497ddc9085f"]}, "showAllNumbers": false}', E'2026-11-21 20:39:31.722384+00'),
  (E'44f8e4fa-ff67-479b-9707-49a7f9e0cd9a', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'{"i": 1, "id": "44f8e4fa-ff67-479b-9707-49a7f9e0cd9a", "qs": [{"id": "9a29bd7c-180d-4661-9224-4f3a788ffc07", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "be230674-f486-4ed5-8ede-6e080e229810", "text": "Вариант ответа 1"}, {"id": "f16380c7-b60c-4c72-8bb4-d56b1f714dc8", "text": "Вариант ответа 2"}, {"id": "9ea6e61e-0a17-49c6-b167-a084d93c4e60", "text": "Вариант ответа 3"}, {"id": "35d6867b-7fb8-4d30-9a47-b39cca8ce463", "text": "Вариант ответа 4"}], "created_at": "2026-11-21T22:54:53.528719+00:00", "image_path": "360:storage:77a75e99-8785-47a0-9832-de1dc5c4087c"}, {"id": "a9a95b68-fbe8-4001-abaf-1da0ea627370", "prompt": "Определи патологию.", "options": [{"id": "fe735722-b33b-49d9-89fd-3927e184eeb4", "text": "Аденоматозный полип толстой кишки"}, {"id": "7314237b-7964-4f58-9c7f-68b732a474ad", "text": "Гиперпластический полип"}, {"id": "f42dc7ac-8d49-46e6-b53c-048c90ddcd36", "text": "Аденоматозный полип желудка"}, {"id": "e4b48e0c-de5f-4649-8c0f-87b8227e382f", "text": "Дивертикул Меккеля"}], "created_at": "2026-10-22T18:43:02.531354+00:00", "image_path": "questions/34d6520a-0e51-4ed2-bad3-bc8b74b6e410.jpg"}, {"id": "7c368354-ed4d-4e5c-9f5a-235b531a3ad1", "prompt": "Пациентка 67 лет. Страдала от прогрессирующего запора, вздутия живота, слабости и потери аппетита. Определи патологию.", "options": [{"id": "4df5c206-3646-42ec-83cb-6e00accdaccd", "text": "Аденоматозный полип толстой кишки"}, {"id": "d4a7270c-dfed-4416-89ec-fad2be40fb62", "text": "Аденокарцинома желудка"}, {"id": "17a31d69-36aa-42ec-b188-762f707d9992", "text": "Аденокарцинома толстой кишки"}, {"id": "93b27970-86b9-4cb8-8875-8cbe3a79353e", "text": "Дивертикулез"}], "created_at": "2026-10-22T18:28:18.627227+00:00", "image_path": "questions/cc3558f5-32b6-459a-bfc7-6498568e3113.jpg"}, {"id": "81612ea5-581a-4671-9a40-dfc9df29c95a", "prompt": "Определи патологию.", "options": [{"id": "3db29956-81e8-457a-9c38-683cf85e9569", "text": "Аденокарцинома из ворсинчатой ​​аденомы"}, {"id": "583c56a9-63ee-4b14-bf3b-8d7f32052080", "text": "Одиночный дивертикул ободочной кишки"}, {"id": "bdd57ec8-a5dc-47a3-bf39-f323e04aeb1a", "text": "Гиперпластический полип"}, {"id": "3329a09e-4807-4542-92b4-7d9103e6437e", "text": "Лимфофолликулярная гиперплазия слизистой оболочки"}], "created_at": "2026-10-23T10:54:09.657298+00:00", "image_path": "questions/ecb319d1-77f3-469a-a250-98e65e001501.jpg"}], "t0": 1795302323582, "mode": "macro", "answers": {}, "savedAt": 1795302342108, "marathon": false, "taskOrder": [["81612ea5-581a-4671-9a40-dfc9df29c95a"], ["9a29bd7c-180d-4661-9224-4f3a788ffc07"], ["7c368354-ed4d-4e5c-9f5a-235b531a3ad1"], ["a9a95b68-fbe8-4001-abaf-1da0ea627370"]], "isMarathon": false, "optionOrder": {"7c368354-ed4d-4e5c-9f5a-235b531a3ad1": ["93b27970-86b9-4cb8-8875-8cbe3a79353e", "17a31d69-36aa-42ec-b188-762f707d9992", "4df5c206-3646-42ec-83cb-6e00accdaccd", "d4a7270c-dfed-4416-89ec-fad2be40fb62"], "81612ea5-581a-4671-9a40-dfc9df29c95a": ["3329a09e-4807-4542-92b4-7d9103e6437e", "583c56a9-63ee-4b14-bf3b-8d7f32052080", "bdd57ec8-a5dc-47a3-bf39-f323e04aeb1a", "3db29956-81e8-457a-9c38-683cf85e9569"], "9a29bd7c-180d-4661-9224-4f3a788ffc07": ["9ea6e61e-0a17-49c6-b167-a084d93c4e60", "35d6867b-7fb8-4d30-9a47-b39cca8ce463", "f16380c7-b60c-4c72-8bb4-d56b1f714dc8", "be230674-f486-4ed5-8ede-6e080e229810"], "a9a95b68-fbe8-4001-abaf-1da0ea627370": ["7314237b-7964-4f58-9c7f-68b732a474ad", "e4b48e0c-de5f-4649-8c0f-87b8227e382f", "fe735722-b33b-49d9-89fd-3927e184eeb4", "f42dc7ac-8d49-46e6-b53c-048c90ddcd36"]}, "showAllNumbers": false}', E'2026-11-21 23:05:42.084062+00'),
  (E'2444b530-796c-4237-b4ad-307911346cb7', E'385a14c1-9d29-4018-b334-213bde15d199', E'{"i": 0, "id": "2444b530-796c-4237-b4ad-307911346cb7", "qs": [{"id": "a9a95b68-fbe8-4001-abaf-1da0ea627370", "prompt": "Определи патологию.", "options": [{"id": "fe735722-b33b-49d9-89fd-3927e184eeb4", "text": "Аденоматозный полип толстой кишки"}, {"id": "7314237b-7964-4f58-9c7f-68b732a474ad", "text": "Гиперпластический полип"}, {"id": "f42dc7ac-8d49-46e6-b53c-048c90ddcd36", "text": "Аденоматозный полип желудка"}, {"id": "e4b48e0c-de5f-4649-8c0f-87b8227e382f", "text": "Дивертикул Меккеля"}], "created_at": "2026-10-22T18:43:02.531354+00:00", "image_path": "questions/34d6520a-0e51-4ed2-bad3-bc8b74b6e410.jpg"}, {"id": "7c368354-ed4d-4e5c-9f5a-235b531a3ad1", "prompt": "Пациентка 67 лет. Страдала от прогрессирующего запора, вздутия живота, слабости и потери аппетита. Определи патологию.", "options": [{"id": "4df5c206-3646-42ec-83cb-6e00accdaccd", "text": "Аденоматозный полип толстой кишки"}, {"id": "d4a7270c-dfed-4416-89ec-fad2be40fb62", "text": "Аденокарцинома желудка"}, {"id": "17a31d69-36aa-42ec-b188-762f707d9992", "text": "Аденокарцинома толстой кишки"}, {"id": "93b27970-86b9-4cb8-8875-8cbe3a79353e", "text": "Дивертикулез"}], "created_at": "2026-10-22T18:28:18.627227+00:00", "image_path": "questions/cc3558f5-32b6-459a-bfc7-6498568e3113.jpg"}, {"id": "81612ea5-581a-4671-9a40-dfc9df29c95a", "prompt": "Определи патологию.", "options": [{"id": "3db29956-81e8-457a-9c38-683cf85e9569", "text": "Аденокарцинома из ворсинчатой ​​аденомы"}, {"id": "583c56a9-63ee-4b14-bf3b-8d7f32052080", "text": "Одиночный дивертикул ободочной кишки"}, {"id": "bdd57ec8-a5dc-47a3-bf39-f323e04aeb1a", "text": "Гиперпластический полип"}, {"id": "3329a09e-4807-4542-92b4-7d9103e6437e", "text": "Лимфофолликулярная гиперплазия слизистой оболочки"}], "created_at": "2026-10-23T10:54:09.657298+00:00", "image_path": "questions/ecb319d1-77f3-469a-a250-98e65e001501.jpg"}], "t0": 1795116547871, "mode": "macro", "answers": {}, "savedAt": 1795116547872, "marathon": false, "taskOrder": [], "isMarathon": false, "optionOrder": {}, "showAllNumbers": false}', E'2026-11-19 19:29:08.192736+00'),
  (E'f341610b-093a-475b-ab04-037b9d3b5396', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'{"i": 2, "id": "f341610b-093a-475b-ab04-037b9d3b5396", "qs": [{"id": "0922a960-a89d-4bde-b07e-6821a6cd42ad", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "3dafc49f-9595-4f06-ae0b-3f4a8ced50e3", "text": "Себорейный кератоз"}, {"id": "e794dae6-8ee0-4bcb-ad36-b9c44c222e7f", "text": "Лимфаденит"}, {"id": "ed01131e-e37e-4d32-a92e-40ee0156a77e", "text": "Папиллярный рак почки"}, {"id": "406c1fe1-8266-410f-b3c6-973fa16564a5", "text": "Папиллома кожи"}], "created_at": "2026-11-19T17:51:28.58288+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}, {"id": "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d", "prompt": "Какой ТПП?", "options": [{"id": "14cfd792-4774-4394-a1ed-4f30ae1dd468", "text": "Воспаление"}, {"id": "f2dea413-8ed3-4d41-a922-293be38a200d", "text": "Опухоль"}, {"id": "22b8c237-4618-46dd-80d1-ebc4c2393681", "text": "Приспособление"}, {"id": "63079ea7-a66e-4f59-9ded-0e9a2dbcd12f", "text": "Нарушение кровообращения"}], "created_at": "2026-11-19T18:50:04.062365+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}, {"id": "886b3875-96f5-49e2-8f9b-256823c92515", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "da3be6e9-83c5-47ad-8c64-dd5f7f475b26", "text": "Вариант ответа 1"}, {"id": "b1f7ac4e-4551-4848-a2e1-d42a37d454a0", "text": "Вариант ответа 2"}, {"id": "b4815109-2d87-4005-9e6a-1ea04631d201", "text": "Вариант ответа 3"}, {"id": "4557c749-b07d-49c5-8344-ce9bf93aa4d5", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T20:23:10.922682+00:00", "image_path": "360:storage:41e81338-a044-492b-b615-f78ca01c0fdb"}, {"id": "3c8cf418-8d80-477b-b431-ecb0d894486b", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "daa3cc4b-de16-4484-a354-069297e94a5c", "text": "Вариант ответа 1"}, {"id": "78d4fe78-d6aa-4de3-b709-04399f3d0ae9", "text": "Вариант ответа 2"}, {"id": "fa066726-5c57-4bd4-af52-892e2ba7e7e6", "text": "Вариант ответа 3"}, {"id": "b31e0669-ab25-40f0-b7b0-76086025d2b5", "text": "Вариант ответа 4"}], "created_at": "2026-11-20T00:37:13.071227+00:00", "image_path": "360:storage:68f4f4ca-412d-44ab-b86b-e3b6d10a4333"}, {"id": "3ff4a71b-dbe7-43cc-aed9-f4032c3f5912", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "1986638c-76b2-4d25-b0d6-23fc06da51e3", "text": "Вариант ответа 1"}, {"id": "a55d9ba4-acd9-4d30-9946-6ddae52fab24", "text": "Вариант ответа 2"}, {"id": "4d5caf12-0864-4fd8-b371-f63b77ca04a0", "text": "Вариант ответа 3"}, {"id": "a83bfe05-85ae-49c4-94c1-867bc74afdd9", "text": "Вариант ответа 4"}], "created_at": "2026-11-20T00:29:15.640366+00:00", "image_path": "360:storage:7c2aa764-945c-4f17-8874-c9407aa67a54"}, {"id": "a7a51068-6b31-40be-a10d-3cce26fee416", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "8a3f3572-0953-4599-9e98-cf48f408da06", "text": "Вариант ответа 1"}, {"id": "159027a3-5d4d-4e31-870c-57c19c042923", "text": "Вариант ответа 2"}, {"id": "c4d7068b-094b-4405-b284-1497ddc9085f", "text": "Вариант ответа 3"}, {"id": "eb8e51b9-9860-49ba-8400-4d096bc18272", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T20:33:07.011062+00:00", "image_path": "360:storage:ac0a0540-391b-4c47-a56f-75df0d53416d"}, {"id": "b384f160-6a8d-422c-abb8-dba32e3d78f9", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "d3e13b45-dad9-441c-860f-61c8160745e5", "text": "Вариант ответа 1"}, {"id": "22fa84a1-110c-4a9e-9af3-03fad983bbb9", "text": "Вариант ответа 2"}, {"id": "3ba99ae7-f025-47d3-b61f-3bfade562e57", "text": "Вариант ответа 3"}, {"id": "ee84e230-d213-435c-8ff8-f4e49ae25363", "text": "Вариант ответа 4"}], "created_at": "2026-11-19T19:55:14.432145+00:00", "image_path": "360:storage:c3361ad1-0cf7-48a6-80eb-2f6010842e88"}], "t0": 1795293651564, "mode": "exam", "answers": {}, "savedAt": 1795293760220, "marathon": false, "taskOrder": [["3c8cf418-8d80-477b-b431-ecb0d894486b"], ["886b3875-96f5-49e2-8f9b-256823c92515"], ["b384f160-6a8d-422c-abb8-dba32e3d78f9"], ["0922a960-a89d-4bde-b07e-6821a6cd42ad", "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d"], ["3ff4a71b-dbe7-43cc-aed9-f4032c3f5912"], ["a7a51068-6b31-40be-a10d-3cce26fee416"]], "isMarathon": false, "optionOrder": {"3c8cf418-8d80-477b-b431-ecb0d894486b": ["daa3cc4b-de16-4484-a354-069297e94a5c", "78d4fe78-d6aa-4de3-b709-04399f3d0ae9", "b31e0669-ab25-40f0-b7b0-76086025d2b5", "fa066726-5c57-4bd4-af52-892e2ba7e7e6"], "886b3875-96f5-49e2-8f9b-256823c92515": ["da3be6e9-83c5-47ad-8c64-dd5f7f475b26", "b4815109-2d87-4005-9e6a-1ea04631d201", "4557c749-b07d-49c5-8344-ce9bf93aa4d5", "b1f7ac4e-4551-4848-a2e1-d42a37d454a0"], "b384f160-6a8d-422c-abb8-dba32e3d78f9": ["22fa84a1-110c-4a9e-9af3-03fad983bbb9", "ee84e230-d213-435c-8ff8-f4e49ae25363", "3ba99ae7-f025-47d3-b61f-3bfade562e57", "d3e13b45-dad9-441c-860f-61c8160745e5"]}, "showAllNumbers": false}', E'2026-11-21 20:42:40.410492+00'),
  (E'bfeb1204-7fc6-444b-8fb2-dbd10c81fd51', E'385a14c1-9d29-4018-b334-213bde15d199', E'{"i": 0, "id": "bfeb1204-7fc6-444b-8fb2-dbd10c81fd51", "qs": [{"id": "0922a960-a89d-4bde-b07e-6821a6cd42ad", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "3dafc49f-9595-4f06-ae0b-3f4a8ced50e3", "text": "Себорейный кератоз"}, {"id": "e794dae6-8ee0-4bcb-ad36-b9c44c222e7f", "text": "Лимфаденит"}, {"id": "ed01131e-e37e-4d32-a92e-40ee0156a77e", "text": "Папиллярный рак почки"}, {"id": "406c1fe1-8266-410f-b3c6-973fa16564a5", "text": "Папиллома кожи"}], "created_at": "2026-11-19T17:51:28.58288+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}, {"id": "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d", "prompt": "Какой ТПП?", "options": [{"id": "14cfd792-4774-4394-a1ed-4f30ae1dd468", "text": "Воспаление"}, {"id": "f2dea413-8ed3-4d41-a922-293be38a200d", "text": "Опухоль"}, {"id": "22b8c237-4618-46dd-80d1-ebc4c2393681", "text": "Приспособление"}, {"id": "63079ea7-a66e-4f59-9ded-0e9a2dbcd12f", "text": "Нарушение кровообращения"}], "created_at": "2026-11-19T18:50:04.062365+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}], "t0": 1795116555671, "mode": "exam", "answers": {"0922a960-a89d-4bde-b07e-6821a6cd42ad": {"chosen": "406c1fe1-8266-410f-b3c6-973fa16564a5", "correct": true, "correctId": "406c1fe1-8266-410f-b3c6-973fa16564a5", "explanation": "Макропрепарат представлен лоскутом кожи размером 3х1х1,5см. На поверхности экзофитно растущий сосочковый вырост. Папиллома кожи."}}, "savedAt": 1795116605791, "marathon": false, "taskOrder": [["0922a960-a89d-4bde-b07e-6821a6cd42ad", "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d"]], "isMarathon": false, "optionOrder": {"0922a960-a89d-4bde-b07e-6821a6cd42ad": ["3dafc49f-9595-4f06-ae0b-3f4a8ced50e3", "406c1fe1-8266-410f-b3c6-973fa16564a5", "ed01131e-e37e-4d32-a92e-40ee0156a77e", "e794dae6-8ee0-4bcb-ad36-b9c44c222e7f"], "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d": ["f2dea413-8ed3-4d41-a922-293be38a200d", "22b8c237-4618-46dd-80d1-ebc4c2393681", "63079ea7-a66e-4f59-9ded-0e9a2dbcd12f", "14cfd792-4774-4394-a1ed-4f30ae1dd468"]}, "showAllNumbers": false}', E'2026-11-19 19:30:05.95745+00'),
  (E'e4bde9e6-a053-4aaf-9456-c1c567c0d01e', E'385a14c1-9d29-4018-b334-213bde15d199', E'{"i": 0, "id": "e4bde9e6-a053-4aaf-9456-c1c567c0d01e", "qs": [{"id": "0922a960-a89d-4bde-b07e-6821a6cd42ad", "prompt": "Определите патологический процесс по макропрепарату.", "options": [{"id": "3dafc49f-9595-4f06-ae0b-3f4a8ced50e3", "text": "Себорейный кератоз"}, {"id": "e794dae6-8ee0-4bcb-ad36-b9c44c222e7f", "text": "Лимфаденит"}, {"id": "ed01131e-e37e-4d32-a92e-40ee0156a77e", "text": "Папиллярный рак почки"}, {"id": "406c1fe1-8266-410f-b3c6-973fa16564a5", "text": "Папиллома кожи"}], "created_at": "2026-11-19T17:51:28.58288+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}, {"id": "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d", "prompt": "Какой ТПП?", "options": [{"id": "14cfd792-4774-4394-a1ed-4f30ae1dd468", "text": "Воспаление"}, {"id": "f2dea413-8ed3-4d41-a922-293be38a200d", "text": "Опухоль"}, {"id": "22b8c237-4618-46dd-80d1-ebc4c2393681", "text": "Приспособление"}, {"id": "63079ea7-a66e-4f59-9ded-0e9a2dbcd12f", "text": "Нарушение кровообращения"}], "created_at": "2026-11-19T18:50:04.062365+00:00", "image_path": "360:storage:0dc587f4-73b1-4c50-b4d7-3840256e928e"}], "t0": 1795116736363, "mode": "exam", "answers": {}, "savedAt": 1795116736365, "marathon": false, "taskOrder": [["0922a960-a89d-4bde-b07e-6821a6cd42ad", "5045e5cb-0cfe-42af-902b-f1d4e0f67b7d"]], "isMarathon": false, "optionOrder": {}, "showAllNumbers": false}', E'2026-11-19 19:32:16.593964+00');



--
-- Data for Name: attempts; Type: TABLE DATA; Schema: public; Owner: -
--

-- Imported 43 rows into public.attempts
INSERT INTO public.attempts (id, user_id, mode, topic_id, question_count, correct_count, duration_seconds, created_at, status, finished_at) VALUES
  (E'1773e603-9863-4555-ad00-d3386e505d3d', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'macro', E'15', E'3', E'0', NULL, E'2026-11-21 19:01:22.79911+00', E'in_progress', NULL),
  (E'76c27182-6425-4852-b9a9-e499ecbc6e23', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'exam', NULL, E'7', E'0', NULL, E'2026-11-21 19:21:28.191837+00', E'in_progress', NULL),
  (E'1775a8e2-78c5-4ec9-9443-98a2067d79d0', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'exam', NULL, E'7', E'0', NULL, E'2026-11-21 19:21:39.42313+00', E'in_progress', NULL),
  (E'565751e3-dfcd-4079-9879-2c62b9093f71', NULL, E'macro', E'15', E'3', E'0', NULL, E'2026-11-21 20:17:55.136571+00', E'in_progress', NULL),
  (E'e8e3ef4e-1436-4cd3-9b5e-554a10234cd2', NULL, E'exam', NULL, E'7', E'0', NULL, E'2026-11-21 20:28:11.720104+00', E'in_progress', NULL),
  (E'e51653b4-2920-4851-bfa1-69e4067ef090', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'exam', NULL, E'7', E'0', NULL, E'2026-11-21 20:37:38.212153+00', E'in_progress', NULL),
  (E'99cacf05-0d22-4544-bf3f-23b6eff8d863', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'exam', NULL, E'8', E'0', NULL, E'2026-11-21 20:44:11.554149+00', E'in_progress', NULL),
  (E'9bcf5a10-c722-4358-abcd-ece92aa0676f', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'exam', NULL, E'1', E'0', NULL, E'2026-11-21 22:40:14.2087+00', E'in_progress', NULL),
  (E'bfeb1204-7fc6-444b-8fb2-dbd10c81fd51', E'385a14c1-9d29-4018-b334-213bde15d199', E'exam', NULL, E'2', E'0', NULL, E'2026-11-19 19:29:15.668302+00', E'in_progress', NULL),
  (E'68e92580-e2ca-40f4-883d-a7f51fefc606', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'exam', NULL, E'4', E'0', NULL, E'2026-11-21 23:03:44.501633+00', E'in_progress', NULL),
  (E'22d657d1-479f-4b74-863e-0f3ba5fdd418', NULL, E'exam', NULL, E'7', E'0', NULL, E'2026-11-21 15:50:58.574302+00', E'in_progress', NULL),
  (E'b8924c3d-e6aa-45ea-aa54-5ef634b01771', E'8fbe9c9f-d5f0-4c0f-adc4-a702bb5111c1', E'theory', E'15', E'5', E'3', E'75', E'2026-10-24 12:05:12.617374+00', E'finished', E'2026-10-24 12:06:27.941791+00'),
  (E'1b4ef5a4-9903-4db6-8375-2f7ca1c2c0c4', E'8fbe9c9f-d5f0-4c0f-adc4-a702bb5111c1', E'theory', E'15', E'5', E'3', E'48', E'2026-10-24 14:27:33.263705+00', E'finished', E'2026-10-24 14:28:21.222922+00'),
  (E'665ee3a1-27ed-4039-88b1-2ae15f090157', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'exam', NULL, E'7', E'0', NULL, E'2026-11-21 19:06:03.717711+00', E'in_progress', NULL),
  (E'e42f2d54-2082-44c1-ba71-0e834d55a38a', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'exam', NULL, E'7', E'0', NULL, E'2026-11-21 19:06:22.169774+00', E'in_progress', NULL),
  (E'c415c9d8-e2f5-4863-962f-e150c14c73cf', NULL, E'exam', NULL, E'7', E'0', NULL, E'2026-11-21 20:08:18.219972+00', E'in_progress', NULL),
  (E'1b8c58f7-1d7f-4283-83d7-c51440e67ff9', E'8fbe9c9f-d5f0-4c0f-adc4-a702bb5111c1', E'macro', E'15', E'3', E'0', NULL, E'2026-10-25 21:05:36.922797+00', E'in_progress', NULL),
  (E'f03b1d04-6056-435e-9917-78d765087ad7', E'8fbe9c9f-d5f0-4c0f-adc4-a702bb5111c1', E'theory', E'1', E'30', E'0', NULL, E'2026-10-25 21:05:56.101527+00', E'in_progress', NULL),
  (E'80760719-ab97-452a-8bca-eb3dc92e3a0c', E'8fbe9c9f-d5f0-4c0f-adc4-a702bb5111c1', E'theory', E'2', E'32', E'0', NULL, E'2026-10-25 21:06:02.675436+00', E'in_progress', NULL),
  (E'72d35205-8ea9-477c-9e06-b44c65f5b666', E'8fbe9c9f-d5f0-4c0f-adc4-a702bb5111c1', E'theory', E'3', E'33', E'0', NULL, E'2026-10-25 21:06:04.342793+00', E'in_progress', NULL),
  (E'51b74c28-c896-4228-b3ba-d678411926e1', E'8fbe9c9f-d5f0-4c0f-adc4-a702bb5111c1', E'theory', E'5', E'35', E'0', NULL, E'2026-10-25 21:06:06.038549+00', E'in_progress', NULL),
  (E'b2105aa5-cd7a-4d07-9b38-34774e521230', E'8fbe9c9f-d5f0-4c0f-adc4-a702bb5111c1', E'theory', E'1', E'30', E'0', NULL, E'2026-10-25 21:06:18.26545+00', E'in_progress', NULL),
  (E'2f3345fa-9e88-4fe1-b320-58f36851207f', NULL, E'exam', NULL, E'7', E'0', NULL, E'2026-11-21 20:25:49.028383+00', E'in_progress', NULL),
  (E'03a064bf-ba0b-4595-abaf-833244071dca', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'exam', NULL, E'7', E'0', NULL, E'2026-11-21 20:28:38.344356+00', E'in_progress', NULL),
  (E'f341610b-093a-475b-ab04-037b9d3b5396', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'exam', NULL, E'7', E'0', NULL, E'2026-11-21 20:40:51.628373+00', E'in_progress', NULL),
  (E'6e871a06-fbf9-44cb-968b-7fd7cff49887', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'exam', NULL, E'8', E'0', NULL, E'2026-11-21 21:20:28.503777+00', E'in_progress', NULL),
  (E'b22e80a4-6e82-4e46-80ef-224a35d85a18', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'exam', NULL, E'2', E'0', NULL, E'2026-11-21 22:48:52.041956+00', E'in_progress', NULL),
  (E'44f8e4fa-ff67-479b-9707-49a7f9e0cd9a', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'macro', E'15', E'4', E'0', NULL, E'2026-11-21 23:05:23.451076+00', E'in_progress', NULL),
  (E'895a5d09-6702-49bb-bd65-1f9f9181129b', NULL, E'macro', E'15', E'3', E'0', NULL, E'2026-11-21 11:23:28.222615+00', E'in_progress', NULL),
  (E'f8adac28-6dce-4ba6-baf9-543a5143aaf5', NULL, E'exam', NULL, E'7', E'0', NULL, E'2026-11-21 17:27:23.196016+00', E'in_progress', NULL),
  (E'e7fc5f90-9ecd-42c3-87ac-dc7fedaca4a9', E'78fa4aca-f030-4ed9-983d-f7a4a39b54bb', E'theory', E'1', E'30', E'0', NULL, E'2026-10-26 02:55:03.381862+00', E'in_progress', NULL),
  (E'79fb1d44-98ff-44b7-9213-d34b25fa4325', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'exam', NULL, E'7', E'0', NULL, E'2026-11-21 19:06:14.265095+00', E'in_progress', NULL),
  (E'4be66820-0a31-4258-86b0-40d85ae2c37e', NULL, E'exam', NULL, E'7', E'0', NULL, E'2026-11-21 20:17:46.376737+00', E'in_progress', NULL),
  (E'81187607-d674-4ae8-b8e9-015aa9101af7', NULL, E'macro', E'15', E'3', E'0', NULL, E'2026-11-21 20:26:44.288256+00', E'in_progress', NULL),
  (E'b5d2634b-2c75-42e1-8bad-73d1b3085f00', NULL, E'exam', NULL, E'7', E'0', NULL, E'2026-11-21 20:33:50.007517+00', E'in_progress', NULL),
  (E'b9b3849c-48fd-4290-9150-94150e989f07', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'exam', NULL, E'7', E'0', NULL, E'2026-11-21 20:43:36.748252+00', E'in_progress', NULL),
  (E'8bf0ef6f-1482-495c-8cc8-123bfd2e0fc8', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'exam', NULL, E'9', E'0', NULL, E'2026-11-21 22:32:28.188089+00', E'in_progress', NULL),
  (E'4253698e-a5c7-4eee-9dcc-b16a2350c2c4', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'exam', NULL, E'3', E'0', NULL, E'2026-11-21 22:50:46.586371+00', E'in_progress', NULL),
  (E'2444b530-796c-4237-b4ad-307911346cb7', E'385a14c1-9d29-4018-b334-213bde15d199', E'macro', E'15', E'3', E'0', NULL, E'2026-11-19 19:29:07.848152+00', E'in_progress', NULL),
  (E'e4bde9e6-a053-4aaf-9456-c1c567c0d01e', E'385a14c1-9d29-4018-b334-213bde15d199', E'exam', NULL, E'2', E'0', NULL, E'2026-11-19 19:32:16.353997+00', E'in_progress', NULL),
  (E'5551f505-c8a7-4021-a862-6a3358cbf6c9', E'385a14c1-9d29-4018-b334-213bde15d199', E'exam', NULL, E'2', E'0', NULL, E'2026-11-19 19:32:42.564241+00', E'in_progress', NULL),
  (E'c00b98bc-3dcd-4e14-aada-490c12ad825f', NULL, E'exam', NULL, E'7', E'0', NULL, E'2026-11-21 11:23:57.038244+00', E'in_progress', NULL),
  (E'136008d5-3a12-457e-98e5-07d640a9ea83', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'macro', E'15', E'3', E'0', NULL, E'2026-11-21 19:00:00.515127+00', E'in_progress', NULL);



--
-- Data for Name: learning_materials; Type: TABLE DATA; Schema: public; Owner: -
--

-- Imported 2 rows into public.learning_materials
INSERT INTO public.learning_materials (id, kind, title, body, url, sort_order, is_published, created_by, created_at, updated_at, file_path, file_name, file_size) VALUES
  (E'22f0cd85-cd38-41d9-9988-758acb8441f1', E'Учебник', E'Патан за ночь', E'', NULL, E'0', E't', NULL, E'2026-10-23 21:54:59.201742+00', E'2026-10-23 21:54:59.201742+00', E'materials/789984d1-2880-4f23-95a4-404c19da129e.pdf', E'краткий патан.pdf', E'360409'),
  (E'2f604508-7f08-489a-95f9-060c427705c1', E'Учебник', E'Краткий патан Струков', E'', NULL, E'0', E't', NULL, E'2026-10-23 21:56:06.017532+00', E'2026-10-23 21:56:06.017532+00', E'materials/0268ed71-c1f0-4ec8-8d86-9b83f4010359.pdf', E'Серов краткий патан.pdf', E'4177713');



--
-- Data for Name: notifications; Type: TABLE DATA; Schema: public; Owner: -
--

-- Imported 1 rows into public.notifications
INSERT INTO public.notifications (id, title, body, created_at, created_by) VALUES
  (E'161e6f4c-6114-4e5a-a67a-beda8ff39519', E'Привие', E'Привет', E'2026-10-29 20:04:32.340939+00', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2');



--
-- Data for Name: profiles; Type: TABLE DATA; Schema: public; Owner: -
--

-- Imported 6 rows into public.profiles
INSERT INTO public.profiles (id, username, nickname, avatar_url, created_at) VALUES
  (E'53b13ae4-b411-4c8d-8ff3-b23d2ad08a54', E'dyuminvad', E'dyuminvad', NULL, E'2026-10-22 16:27:02.543116+00'),
  (E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'dyuminvad1', E'admin111', NULL, E'2026-10-22 16:32:28.545737+00'),
  (E'385a14c1-9d29-4018-b334-213bde15d199', E'daiasay', E'Daria', NULL, E'2026-10-23 17:30:08.456372+00'),
  (E'8fbe9c9f-d5f0-4c0f-adc4-a702bb5111c1', E'stukalovaul', E'УляС', NULL, E'2026-10-23 17:20:13.313037+00'),
  (E'78fa4aca-f030-4ed9-983d-f7a4a39b54bb', E'240799', E'Милена', NULL, E'2026-10-24 09:26:44.799855+00'),
  (E'9c46b562-06a3-4efb-ad63-65266e3366aa', E'vitad', E'VI', NULL, E'2026-10-31 06:33:05.855254+00');



--
-- Data for Name: question_answers; Type: TABLE DATA; Schema: public; Owner: -
--

-- Imported 403 rows into public.question_answers
INSERT INTO public.question_answers (question_id, correct_option_id, explanation) VALUES
  (E'7c07057a-982d-418f-abe5-c26649151f65', E'83b329a1-925f-4dbe-b564-846308359244', E'Дистрофия — патологический процесс, связанный с нарушением обмена веществ в клетках или тканях и сопровождающийся структурными изменениями. Накопление или утрата компонентов клетки может нарушать её функцию; исход зависит от причины и тяжести повреждения. Нарушение кровообращения может вызывать отёк, но не охватывает все дистрофии; компенсаторное увеличение числа клеток относится к гиперплазии; необратимая гибель ткани — это не обязательный признак дистрофии, а возможный исход тяжёлого повреждения.'),
  (E'056d6796-3437-49aa-a2e1-8b83cb6e7f5e', E'2484ccc4-1353-4067-9e75-c81c14f00ea9', E'Дистрофии классифицируют по локализации (паренхиматозные, стромально-сосудистые, смешанные), виду нарушенного обмена, распространённости и происхождению. Эти признаки помогают описать, где развивается процесс, какие вещества накапливаются и является ли поражение местным или системным. Цвет органа и возраст сами по себе не являются основными классификационными критериями; воспаление не обязательно сопровождает дистрофию; форма органа и характер кровоснабжения могут иметь диагностическое значение, но не образуют принятую классификацию дистрофий.'),
  (E'c0edcfb3-1a0f-4254-98f7-1ada8b44efe7', E'32d25f67-dc07-4512-b8e4-6918f669469e', E'Основные механизмы морфогенеза дистрофий: инфильтрация, декомпозиция, извращённый синтез и трансформация. При инфильтрации вещества поступают и накапливаются, при декомпозиции распадаются структуры, при извращённом синтезе образуются необычные продукты, а при трансформации одни вещества превращаются в другие. Инфильтрация, декомпозиция и извращённый синтез действительно относятся к механизмам дистрофий; эмболия означает закупорку сосуда материалом, принесённым током крови, и относится к нарушениям кровообращения.'),
  (E'e42319a0-9585-4068-aba3-dd3b082d9ee4', E'47a45bde-5515-4003-b45f-cc9b2500eea7', E'Декомпозиция (фанероз) — распад клеточных ультраструктур или межклеточного вещества с последующим накоплением продуктов распада. Повреждение мембран и органелл нарушает обмен внутри клетки и может приводить к появлению патологических включений. Трансформация означает образование одного вещества из другого; инфильтрация связана с избыточным поступлением веществ; извращённый синтез — с образованием аномальных продуктов, а не с распадом структур.'),
  (E'7c368354-ed4d-4e5c-9f5a-235b531a3ad1', E'17a31d69-36aa-42ec-b188-762f707d9992', E'На разрезе толстой кишки видна бледная, грибовидная и изъязвленная кольцевидная/циркулярная опухоль, исходящая из слизистой оболочки. Опухоль проросла через мышечный слой в подсерозную жировую ткань. Имеются очаги некроза опухоли. Полипы не обнаружены.'),
  (E'72976e34-b631-4c6e-b365-93a49ba190a5', E'1c402d4b-8f78-409b-b64e-2d141731a6be', E'Заживление обычно начинается с гемостаза и воспаления, которые ограничивают кровопотерю и очищают повреждение. Затем пролиферируют эндотелиальные клетки и фибробласты, формируется грануляционная ткань, после чего матрикс перестраивается и рубец созревает. Склероз не предшествует гемостазу, а атрофия, метаплазия, кальциноз и обязательное нагноение не являются последовательными обязательными этапами нормального заживления.'),
  (E'62af2f62-fcac-48bf-8618-5c18d44125d4', E'2c4d8af2-5abd-49f3-b329-744d81a1c4d1', NULL),
  (E'6ba889cb-f5b3-40ba-8f03-8a2594888776', E'f6a70a15-7431-4f45-9356-4ec344bae385', E'Аганглиоз поражённого сегмента нарушает перистальтику и приводит к функциональной кишечной непроходимости.'),
  (E'df8943c1-eeb5-4388-b407-1221c464d8d5', E'2a8f1c12-7d22-4991-afc3-f9e2561fc52e', E'Слизистая оболочка особенно чувствительна к ишемии; при прогрессировании повреждение может распространяться на всю толщу кишечной стенки.'),
  (E'18bc9b49-e108-4248-abaf-5e169098cbea', E'fa682234-66d5-471f-88e0-eb8e1a62f359', E'Ангиодисплазия представляет собой аномальное расширение сосудов кишечной стенки и может быть причиной желудочно-кишечных кровотечений.'),
  (E'f7e90987-c01e-46c5-9f9a-f09022ff1fb2', E'e7aebca4-9c45-4203-b565-9a4389ed1b24', E'Дивертикул Меккеля образуется вследствие неполной облитерации желточно-кишечного протока.'),
  (E'bda40b0d-d4e6-496e-a2d0-ca19d0e38a76', E'a9bfd4e0-c5de-4fdc-9074-b166cded81ca', E'Атрезия — врождённое полное отсутствие просвета на определённом участке полого органа'),
  (E'81612ea5-581a-4671-9a40-dfc9df29c95a', E'3db29956-81e8-457a-9c38-683cf85e9569', E'Поверхность новообразования полипоидная и красновато-розовая. Кровоизлияние с поверхности опухоли позволяет обнаружить ее с помощью анализа кала на скрытую кровь. Новообразование располагалось в сигмовидной кишке, вне досягаемости пальцевого ректального исследования, но легко визуализировалось при сигмоскопии.'),
  (E'6b241cf2-b8f8-4400-80f0-a360cb7cd3a5', E'753f88d7-cb64-40fb-98c7-c93fdbcba58b', E'При гиалиново-капельной дистрофии в цитоплазме клеток видны крупные гиалиноподобные белковые капли; это проявление нарушения белкового обмена. В почечных канальцах такие капли могут возникать при усиленной реабсорбции профильтрованных белков, например при протеинурии. Липидные капли характерны для жировой дистрофии; увеличение коллагеновых волокон относится к изменениям стромы; отложение кальция — проявление патологического обызвествления. Для гиалиново-капельной дистрофии характерны белковые капли в цитоплазме.'),
  (E'20294443-8ae8-45ac-8630-9e2a2f99fa78', E'6c89c55a-0786-4a79-862c-e32df79d730d', E'Гиалиново-капельная дистрофия — тяжёлое повреждение клетки; выраженные изменения могут завершаться её гибелью. В отличие от обратимого накопления отдельных белковых капель, массивные изменения цитоплазмы сопровождаются глубоким нарушением клеточных структур. Полное восстановление не характерно для выраженного тяжёлого повреждения при гиалиново-капельной дистрофии; рубец формируется при организации повреждения ткани и не является обязательным исходом внутриклеточной дистрофии; переход в жировую дистрофию не является закономерным.'),
  (E'6cad8663-d0e1-4068-9759-8c8aaedb4af6', E'f1e24ea7-f3b1-4428-a852-201025cfd012', E'Тельца Мэллори — скопления повреждённых цитоскелетных белков в цитоплазме гепатоцитов; они характерны прежде всего для алкогольного гепатита. Основу включений составляют агрегаты кератинов, в том числе кератинов 8 и 18; при микроскопии они выглядят как эозинофильные цитоплазматические массы. Сахарный диабет без поражения печени сам по себе не объясняет тельца Мэллори; инфаркт печени связан с ишемическим некрозом; кальций в гепатоцитах не образует характерных цитоскелетных включений. Тельца Мэллори состоят преимущественно из агрегатов кератинов.'),
  (E'73fb80e6-f5bc-475b-88df-beec0eaab466', E'402e51c3-c4c6-43af-945e-a0f2e83697a4', E'При гидропической дистрофии нарушается водно-электролитный баланс клетки, вода накапливается в цитоплазме и формирует вакуоли. Обычно это связано с повреждением мембран и снижением эффективности ионных насосов, поддерживающих нормальное распределение натрия и калия. Накопление нейтрального жира описывает жировую, а не гидропическую дистрофию; ограничение стромой неверно, поскольку процесс развивается внутри клеток; влияние на функцию возможно и зависит от тяжести повреждения.'),
  (E'3747c271-34e2-45d6-b17f-2f632a551caf', E'd1bfa73a-22b9-4aa1-bdd3-b0b2c293de27', E'При тяжёлой гидропической дистрофии клетка резко набухает; возможны баллонная дистрофия и колликвационный некроз. При баллонной дистрофии цитоплазма становится резко светлой и разреженной, а при необратимом повреждении клетка погибает. Полное восстановление возможно при обратимом повреждении, но не является единственным исходом тяжёлого процесса; амилоид не образуется как обязательное следствие гидропической дистрофии; гиперкератоз относится к нарушениям ороговения эпителия.'),
  (E'23d9a0da-077c-4473-94a6-498563bb8648', E'40f02761-7705-4905-ba50-73f55b4fda00', E'Гидропическая дистрофия гепатоцитов может наблюдаться при вирусном гепатите вследствие повреждения клеток и нарушения их водно-электролитного баланса. При микроскопии выявляют набухание гепатоцитов и светлую вакуолизированную цитоплазму; выраженность изменений зависит от степени повреждения. Гипертоническая болезнь и атеросклероз не являются типичными причинами гидропической дистрофии гепатоцитов; перелом кости непосредственно не вызывает характерное изменение печени. При вирусном гепатите повреждение гепатоцитов может нарушать ионный баланс и вызывать вакуолизацию.'),
  (E'28ce84b0-e67a-43aa-b044-346551156287', E'8130f7c9-ae6d-41e6-8f07-d69aed40e473', E'Роговая дистрофия — избыточное образование рогового вещества в ороговевающем эпителии или патологическое ороговение эпителия, который обычно не ороговевает. К проявлениям относятся гиперкератоз, ихтиоз и лейкоплакия; клиническое значение определяется локализацией и выраженностью процесса. Накопление триглицеридов относится к жировой дистрофии; белковые капли в канальцах — к гиалиново-капельной дистрофии; кальцификация связана с отложением солей кальция. Роговая дистрофия касается кератинизации эпителия.'),
  (E'c7a7cb27-38d6-45a3-8650-52dfa395a233', E'218a7943-188a-4245-b828-f2a07a0f8bf4', NULL),
  (E'2e2a902e-9d14-4769-9cde-75ae1a45f2d0', E'a35a13eb-4599-482b-aaf8-e8d129793be1', E'Лейкоплакия — патологическое ороговение слизистой оболочки, на которой в норме выраженного ороговения нет. В очаге образуется белесоватая бляшка; для оценки риска важны локализация, длительность существования и наличие эпителиальной дисплазии. Гидропическая дистрофия связана с накоплением воды в клетке, а не с лейкоплакией; ихтиоз относится к нарушениям ороговения, а не жировому обмену; «тигровое сердце» обусловлено жировой дистрофией миокарда, а не гиалиново-капельной.'),
  (E'565e6acc-a394-41b7-88eb-22d04203af0e', E'61702e0d-90c9-402c-98fe-a12482e5649b', E'При длительно существующей лейкоплакии возможно развитие дисплазии эпителия и злокачественной опухоли. Риск неодинаков для разных локализаций и зависит, в частности, от выраженности дисплазии, поэтому стойкие очаги требуют клинической оценки. Лейкоплакия не вызывает обязательного немедленного некроза слизистой; она не является липидозом; наследование не является обязательным свойством. Клинический риск связан с возможным развитием дисплазии и злокачественной опухоли.'),
  (E'2feb4438-9993-4275-b215-2f668234aa1a', E'9385ae2b-87f9-4e2d-9087-08f81dc7c1a5', E'Ихтиоз относится к нарушениям ороговения и проявляется выраженной сухостью и шелушением кожи; тяжёлые врождённые формы могут быть несовместимы с жизнью. Избыточное накопление роговых масс нарушает нормальное слущивание эпидермиса и придаёт коже вид чешуек. Нарушения гликогена и накопление жира не объясняют ихтиоз; гиалиноз сосудов относится к изменениям соединительной ткани и сосудистых стенок. Ихтиоз проявляется патологическим ороговением и шелушением кожи.'),
  (E'565fc072-c314-493e-be35-44f815112ea2', E'1c643fcb-4505-42dd-9311-d9d069598380', E'Для выявления нейтральных липидов используют окраску Суданом III на замороженных срезах, поскольку при стандартной проводке жир растворяется органическими растворителями. Судан III окрашивает липидные капли в оранжево-красный цвет, позволяя подтвердить их наличие в ткани. Гематоксилин и эозин не являются надёжным способом выявления нейтральных липидов после стандартной проводки, поскольку жир растворяется; реакция Перлса выявляет железо; метахромазия толуидиновым синим применяется для выявления определённых компонентов матрикса, а не нейтрального жира.'),
  (E'9cf4ef72-6718-4de8-8272-11b9f08f0cdb', E'ddcd3b12-4c13-4afe-a15b-843da26ada63', E'При стандартной гистологической обработке липиды растворяются спиртами и ксилолом; на их месте остаются пустоты, выглядящие как вакуоли. Поэтому на обычных парафиновых срезах жировые включения чаще видны как оптически пустые пространства, а для подтверждения липидов применяют специальные окраски. Жир не окрашивается в ярко-синий цвет при обычной обработке; липиды не превращаются в кальций; исчезновение ядер не объясняет вакуоли. Пустоты возникают потому, что липиды растворяются при проводке препарата.'),
  (E'f6dd8320-e2a2-488e-afac-39b4a1fefb51', E'7daac1cb-91ba-4138-b56b-4b6abf2858bd', E'При выраженной жировой дистрофии печень обычно увеличена, дряблая и жёлтая на разрезе из-за накопления триглицеридов в гепатоцитах. Микроскопически в цитоплазме появляются липидные вакуоли; крупные капли могут оттеснять ядро к периферии клетки. Уменьшение, плотность и чёрный цвет не типичны для стеатоза печени; бугристость с рубцами скорее указывает на выраженный фиброз/цирроз; отсутствие изменений размера и консистенции противоречит накоплению значительного количества жира.'),
  (E'6ecdd62b-b2ea-49da-9926-e08e6caa0777', E'ceffd664-435f-46de-a0d5-41cb7f5ec171', E'Жир накапливается в печени при избыточном поступлении липидов, снижении их окисления или нарушении образования и выведения липопротеинов. Усиленное выведение липидов не вызывает их накопления: стеатоз развивается, когда поступление и синтез превышают окисление и экспорт из гепатоцитов. Избыточное поступление липидов способствует стеатозу; снижение их окисления уменьшает утилизацию; уменьшение синтеза апопротеинов затрудняет выведение липидов в составе липопротеинов. Напротив, усиленное выведение должно уменьшать, а не увеличивать внутриклеточное накопление жира.'),
  (E'607a3ec4-af76-41b1-bd56-180f3eaaaaa5', E'6858162c-f9a3-46dd-a1ac-8599271f8fa7', E'Периферическое накопление жира в печёночной дольке часто связано с поступлением липидов при гиперлипидемии; при гипоксии сильнее страдают центральные отделы дольки. Центральная зона получает кровь с более низким содержанием кислорода, поэтому особенно чувствительна к гипоксическому повреждению. Декомпозиция при гипоксии чаще проявляется накоплением жира в центральных отделах дольки, где ниже содержание кислорода; некроз всех гепатоцитов не является обязательным; стромальная дистрофия затрагивает соединительную ткань, а не объясняет накопление липидов в гепатоцитах.'),
  (E'3edd286e-256e-407f-8503-45a581a47503', E'9c081f58-ad51-486c-89cc-8e3cf7a54624', E'При жировой дистрофии миокарда жир накапливается в кардиомиоцитах и формирует желтовато-белую исчерченность под эндокардом — «тигровое сердце». Чередование светлых полос с более тёмными участками связано с неравномерным распределением липидов в мышечных волокнах. Равномерное чёрное окрашивание не является признаком жировой дистрофии миокарда; поражение клапанов относится к изменениям клапанного аппарата; увеличение числа кардиомиоцитов не объясняет липидные включения и характерную исчерченность.'),
  (E'1598e104-344b-4c98-864d-c980323c9da8', E'32af7837-1886-43f4-a589-ab5484bc0fe9', E'Гипоксия, в том числе при анемии и хронической сердечно-сосудистой недостаточности, снижает окисление жирных кислот и способствует их накоплению в кардиомиоцитах. При недостатке кислорода уменьшается эффективность митохондриального окисления, а длительное повреждение может ослаблять сократительную функцию миокарда. Гиперкератоз и избыточное ороговение относятся к эпителию; изолированная гиперкальциемия не является типичной причиной накопления жира в кардиомиоцитах. Гипоксия снижает митохондриальное окисление жирных кислот.'),
  (E'5f1aeae5-f81d-4545-b7b3-88d57c32ab2d', E'2ac14d56-cb68-4293-af65-ce6cc81d2fde', E'Жировая дистрофия печени может быть обратимой, если устранить причину до развития выраженного повреждения и гибели гепатоцитов. После прекращения избыточного поступления липидов или восстановления их метаболизма триглицериды могут постепенно удаляться из клеток. Жировая дистрофия не всегда необратима и сама по себе не означает немедленного цирроза; колликвационный некроз не является обязательным исходом; опухоль не возникает как закономерное следствие стеатоза.'),
  (E'1158ed83-d7e2-49c3-8ddf-19e7a8eb9058', E'531c8189-4dcd-4205-8a36-cc597d9d31d2', E'При сахарном диабете нарушения углеводного обмена могут сопровождаться накоплением гликогена в ядрах гепатоцитов, из-за чего они выглядят светлыми или «пустыми». Такие ядра отражают изменение внутриклеточного обмена глюкозы и гликогена, но оцениваются вместе с другими морфологическими признаками диабета. Кальций в ядрах и ороговение гепатоцитов не являются характерными проявлениями диабетического нарушения углеводного обмена; тельца Мэллори связаны прежде всего с повреждением цитоскелета, например при алкогольном поражении печени. Диабет может сопровождаться накоплением гликогена в ядрах.'),
  (E'6a34858d-46d6-4feb-a7e1-3074ca386944', E'f4a5b045-52bd-4aa2-828a-5cebb68265a1', E'При сахарном диабете глюкоза из канальцевого фильтрата может накапливаться в эпителии канальцев в виде гликогена; цитоплазма клеток становится светлой и пенистой. Это изменение связано с высокой концентрацией глюкозы в фильтрате и её поступлением в эпителиальные клетки канальцев. Накопление жира в клубочках не описывает характерное изменение эпителия канальцев; ороговение не свойственно почечным канальцам; изменения не отсутствуют обязательно при глюкозурии, поскольку глюкоза может поступать в клетки канальцев и нарушать обмен.'),
  (E'68e51e1b-702e-4588-b7df-772ddb2d464f', E'1f693593-ee72-4954-b7c8-a4c63130927c', E'При диабетической микроангиопатии в клубочках развивается интеркапиллярный (диабетический) гломерулосклероз: увеличивается количество мезангиального матрикса, что нарушает фильтрацию. При прогрессировании утолщаются базальные мембраны и расширяется мезангий, что способствует альбуминурии и снижению функции почек. Мукоидное набухание — изменение основного вещества соединительной ткани; тельца Каунсильмена — апоптотические гепатоциты при некоторых формах гепатита; лейкоплакия — патологическое ороговение слизистой. Диабетическое поражение клубочков проявляется гломерулосклерозом.'),
  (E'8b9c9ac9-2217-4100-87df-861848f203de', E'49040213-60ad-47d9-b4f9-ffad02a1bc80', E'Гликогенозы — наследственные заболевания, вызванные дефектами ферментов обмена гликогена; клинические проявления зависят от типа дефекта и поражённых тканей. Гликоген накапливается преимущественно в печени, мышцах или других органах, где нарушены его синтез, распад либо использование. Приобретённое воспаление слизистой, жировая дистрофия миокарда и лейкоплакия не являются наследственными нарушениями обмена гликогена. Гликогенозы обусловлены генетическими дефектами ферментов метаболизма гликогена.'),
  (E'7e04afcf-11c4-4fce-a076-f0e6c38903dc', E'33acdbea-ce31-44b6-84f4-e0c2ff169a3f', NULL),
  (E'bbdcdd6f-1b21-4b96-8f12-0cc0a129accd', E'23c9377f-c599-48ea-943b-426643d67ad5', E'Паренхиматозные дистрофии возникают вследствие нарушения обмена в специализированных клетках органов, например печени, почек и сердца. Морфологические проявления зависят от вещества, которое накапливается или утрачивается, и могут включать белковые, жировые и углеводные изменения. Изменения исключительно межклеточного вещества характерны для стромально-сосудистых процессов; дистрофии относятся к проявлениям повреждения; они бывают как приобретёнными, так и наследственными, поэтому утверждение об исключительно наследственном происхождении неверно.'),
  (E'4fc7082f-3ac6-4f7c-94af-da5c21cfc181', E'8a1b7a90-012f-43f2-b8e1-8f8aa6dfad75', E'Воспаление и опухолевый рост не являются обязательными этапами дистрофий. Их проявления и исход зависят от вида обменного нарушения и тяжести повреждения; изменения могут быть обратимыми либо приводить к гибели клеток и нарушению функции органа. Дистрофии могут быть местными или системными; они бывают приобретёнными и наследственными; по локализации выделяют паренхиматозные, стромально-сосудистые и смешанные формы. Воспаление не обязательно предшествует дистрофии, а опухоль не является её закономерным исходом.'),
  (E'39186242-e6ca-4219-b0ea-9270624810d8', E'308754bc-8f63-4d52-9ab3-edf9810fdbcc', E'Паренхиматозные дистрофии отражают нарушение обмена в клетках органов; при тяжёлом или длительном повреждении возможны снижение функции и гибель клеток. Например, выраженное накопление жира нарушает работу гепатоцитов, а тяжёлая белковая дистрофия может сопровождаться необратимым повреждением клетки. Дистрофии не ограничиваются косметическими изменениями; они имеют морфологические проявления; исход не всегда благоприятен — при тяжёлом или длительном повреждении возможны нарушение функции и гибель клеток.'),
  (E'9ebc5e2c-4920-40a0-b7d3-ab16e505dfcb', E'28c475a3-183e-4249-bf31-3c9de0254553', E'При инфильтрации вещество поступает в клетку или межклеточное вещество в избытке либо недостаточно перерабатывается и выводится, поэтому накапливается. Примерами служат накопление липидов в гепатоцитах и белковых капель в эпителии почечных канальцев при усиленной реабсорбции белка. Распад ультраструктур — это декомпозиция; образование необычных продуктов за счёт синтеза — извращённый синтез; замещение паренхимы соединительной тканью является склерозом, а не механизмом инфильтрации.'),
  (E'1b9eaa13-f44b-4a4a-bf57-a91baf136802', E'8d68cd0e-e173-46cd-b35c-852ed0ef761f', E'Грануляционная ткань — молодая репаративная ткань, богатая новообразованными капиллярами, фибробластами и клетками воспаления. При созревании сосудистость и клеточность снижаются, а коллагеновый матрикс становится плотнее и упорядоченнее. Поэтому плотные коллагеновые пучки при минимальной клеточности характернее для зрелого рубца; отсутствие сосудов и ремоделирования не описывает активную грануляционную ткань.'),
  (E'27f32b95-9f86-4224-8f08-418a91ab027c', E'c565cddc-f30f-4ae8-82a9-b07ed7a18ef5', E'Метапластический вариант патологической регенерации характеризуется заменой одного зрелого типа ткани другим, часто как приспособлением к хроническому раздражению. Субституция закрывает дефект соединительной тканью; гиперплазия увеличивает число клеток без обязательной смены их типа; внутриклеточная регенерация обновляет компоненты внутри прежних клеток. Эти процессы имеют разные морфологические механизмы.'),
  (E'89d6b4c9-5043-4767-bf6b-b6602bb07633', E'd39d99d4-05f1-400c-aef4-83b867abbfd7', E'При артериальной гипертензии левый желудочек преодолевает повышенное сопротивление выбросу, и кардиомиоциты увеличиваются в размерах, формируя рабочую гипертрофию. Стеноз почечной артерии снижает перфузию и может приводить к ишемической атрофии почки. Жировое замещение атрофированных волокон — ложная гипертрофия, а недостаток гормонального сигнала вызывает атрофию зависимой ткани.'),
  (E'ecc68018-f8e3-4171-a1f5-54b319ce6977', E'ab496f9d-4a02-4f5a-9230-3f5733912fd8', E'Денервация лишает мышцу нервной стимуляции и трофического влияния, снижая синтез и поддержание сократительных структур; волокна истончаются, масса и сила мышцы уменьшаются. Усиление синтеза миофибрилл при нагрузке поддерживает гипертрофию, а не атрофию. Гиперплазия зрелых кардиомиоцитов не объясняет изменения скелетной мышцы; при ложной гипертрофии объём может увеличиваться за счёт жира, но функциональные волокна при этом атрофируются.'),
  (E'9a29bd7c-180d-4661-9224-4f3a788ffc07', E'be230674-f486-4ed5-8ede-6e080e229810', NULL),
  (E'b53ea179-72c8-4a18-8809-ac8c76d1bdc5', E'a8bc8279-6009-474f-9804-b536627961d4', E'При первичном натяжении края раны сближены, потеря ткани и объём некроза невелики, поэтому требуется меньше грануляционной ткани и формируется сравнительно небольшой рубец. Воспалительная реакция и эпителизация всё равно необходимы, хотя обычно ограничены. Расхождение краёв увеличивает дефект, а гнойное воспаление поддерживает повреждение и замедляет заживление.'),
  (E'4466e06d-b1db-47c5-9017-74843df0e75d', E'bb8075b1-ccc8-475a-9912-b108f32240c0', E'Гипорегенерация — недостаточное или замедленное восстановление, проявляющееся стойким дефектом. Её поддерживают ишемия, инфекция, сахарный диабет, недостаточное питание и сохраняющийся некроз. Избыточное разрастание за пределами раны соответствует гиперрегенерации; реституция означает полноценное восстановление, а метаплазия — изменение зрелого клеточного типа.'),
  (E'19f9c29d-e4f1-4d60-bcdd-af40256b9c70', E'e9ebb84c-4c1b-42e1-8719-6d28eb852f13', E'Базальные клетки эпидермиса сохраняют способность к делению; их потомки дифференцируются и перемещаются к поверхности, формируя последовательно расположенные слои. Зрелые корнеоциты ороговевшие и не делятся. Замена эпителия фибробластами означала бы рубцевание, а образование ядер без полноценного клеточного деления не создаёт новых функциональных клеток.'),
  (E'4d03a4e1-62b0-44fd-a3fe-25fb7b177a05', E'95b26d62-9006-42ec-bf95-aa62ad6293ad', E'Компенсация является функционально направленной разновидностью адаптации: её задача — поддерживать работу органа при повышенной нагрузке или утрате части ткани. Она может сопровождаться гипертрофией и другими структурными изменениями, поэтому не ограничивается функциональными сдвигами без морфологии. Компенсация не шире адаптации и не гарантирует полного выздоровления: при истощении резервов развивается декомпенсация.'),
  (E'd43715e8-5716-4dfd-a196-a4c7876ec262', E'e5f9d603-8045-4b16-9072-eaabdbd633de', E'Истинная гипертрофия — увеличение размера клеток и массы функциональной паренхимы. Если объём увеличивается за счёт жира или соединительной ткани при истончении функциональных волокон, это ложная гипертрофия. Отёк также увеличивает размер временно, но не отражает роста клеточной массы; увеличение только стромы на фоне утраты паренхимы не означает усиления функции.'),
  (E'539f5835-809c-485d-9ddb-6116fa03db6c', E'1d49b958-9e27-452b-af87-1edb260166a0', E'Дисгормональная атрофия возникает при длительном снижении гормональной стимуляции, необходимой для поддержания структуры и функции ткани. Снижение перфузии вызывает ишемическую атрофию; внешнее сдавление — компрессионную; уменьшение функциональной нагрузки — дисфункциональную. Хотя все варианты могут приводить к уменьшению органа, их различают по ведущей причине.'),
  (E'fc128093-69fb-4c93-b3ac-e67e9706a15f', E'1990f684-c94a-40fe-af42-b93ebaa9e827', E'Компрессионная атрофия связана с длительным внешним давлением, которое может непосредственно деформировать ткань и нарушать микроциркуляцию; примером служит истончение паренхимы при длительном нарушении оттока мочи. Дисфункциональная атрофия обусловлена снижением нагрузки, а дисгормональная — недостатком гормональной стимуляции. Первичная ишемия без механического воздействия относится к ишемическому варианту.'),
  (E'ea709fa7-9879-47f9-8f9c-976ca0f854cc', E'08cf2cc2-7ac6-494f-8563-22df0cfb5711', E'При небольшом повреждении сохранные базальная мембрана и резервные клетки обеспечивают миграцию, пролиферацию и дифференцировку эпителия, поэтому вероятна реституция без грубого рубца. Субституция с плотным коллагеном более вероятна при глубоком повреждении каркаса. Организация грануляционной тканью характерна для более глубоких дефектов, а локальное повреждение эпителия само по себе не вызывает атрофию всего органа.'),
  (E'65c89d3e-da5f-4956-ba0f-43edb1b370e3', E'bd32b943-6dac-4f99-b812-465cd9786d1e', E'Метаплазия бронхиального эпителия при хроническом раздражении — замена мерцательного цилиндрического эпителия многослойным плоским. Такая перестройка повышает устойчивость к раздражению, но ухудшает мукоцилиарный клиренс и может повышать риск дальнейших патологических изменений. Гиперплазия увеличивает число клеток без смены типа, атрофия уменьшает ткань, а организация означает замещение очага повреждения соединительной тканью.'),
  (E'672a576d-b68a-4d45-855c-c7d2cb2e1729', E'27e54b0a-c073-4d5a-be70-f665d850bc9b', E'Гипертрофированные кардиомиоциты требуют больше кислорода и субстратов, однако капиллярная сеть может не увеличиваться пропорционально массе миокарда. Возникают относительная ишемия, нарушения обмена, дистрофия, гибель клеток и фиброз, что ведёт к декомпенсации. Рост капилляров не гарантированно устраняет дисбаланс; превращение паренхимы в макрофаги и исчезновение матрикса не являются механизмами декомпенсации.'),
  (E'ec77f65f-6b11-41cc-bdce-31a64df0dcdb', E'702e0fb2-1a6f-4461-accd-3967eb8bd346', E'Вторичным натяжением заживают раны с большой потерей ткани или расхождением краёв. Дефект заполняется грануляционной тканью, затем сокращается благодаря миофибробластам и постепенно покрывается эпителием; рубец обычно выражен сильнее. Отсутствие воспаления нехарактерно, а немедленное восстановление архитектоники невозможно при значительном дефекте. При первичном натяжении заполнение грануляционной тканью обычно менее выражено.'),
  (E'390e94a5-04d6-491c-9544-9812d31e789a', E'5c9c05ed-2beb-497f-b1d8-c4ff4c48cfea', E'Гиперрегенерация означает избыточное восстановление: возможны чрезмерная грануляционная ткань и патологическое рубцевание, включая келоид, выходящий за границы первоначальной раны. Снижение сосудистости и уплотнение коллагена — нормальное созревание рубца. Эпителизация небольшого дефекта и ограниченный рубец после некроза сами по себе не указывают на избыточную репарацию.'),
  (E'9cfb822a-ae46-4fad-9487-739d46a3640c', E'd06d7b80-e682-4707-8509-2ee36c8deede', E'Кардиомиоциты взрослого человека обладают крайне ограниченной способностью к пролиферации, поэтому обширный инфаркт миокарда обычно не заканчивается реституцией. Некротический очаг очищается, прорастает грануляционной тканью и организуется с формированием коллагенового рубца. Рубец поддерживает целостность стенки, но не обладает сократительной функцией миокарда; образование хряща и превращение фибробластов в миоциты не являются типичными исходами.'),
  (E'839c2da0-09bd-49aa-8000-1fdb24de5e23', E'd53d3ae4-39bf-4171-a235-721e3b8228df', E'Адаптация — структурно-функциональная перестройка, помогающая клетке или органу приспособиться к изменившейся нагрузке или среде. Она не обязательно сопровождается гибелью и может быть обратимой, пока не исчерпаны возможности приспособления. Увеличение числа клеток — лишь один из вариантов адаптивного ответа; отёк и жировое накопление могут увеличивать объём, но не определяют адаптацию.'),
  (E'c56e75e2-4bc3-440b-919d-9726e80a7cbe', E'b7875506-62e0-4ab2-9db8-c62d72efb2b3', E'Дилатация полостей, дистрофические изменения кардиомиоцитов, застой и сердечная недостаточность свидетельствуют, что компенсаторная гипертрофия перестала обеспечивать эффективную работу сердца. Увеличение массы при сохранённой функции характерно для компенсации, а не декомпенсации. Изолированный синтез белка не доказывает повреждения; викарная гипертрофия возникает в оставшемся парном органе после утраты второго, а не при перегрузке миокарда.'),
  (E'67be22ef-0f96-428b-8de0-a56cd8fba379', E'9f51b5ee-241b-42b3-8d55-30c3101bd986', E'Викарная гипертрофия развивается в сохранившемся парном органе после удаления или утраты функции второго, например в единственной почке. Рабочая гипертрофия обусловлена повышенной нагрузкой на сам орган, как при гипертензии в левом желудочке или тренировке скелетной мышцы. Жировое замещение — ложная гипертрофия, а уменьшение органа при снижении нагрузки соответствует атрофии.'),
  (E'7646afbc-1ac6-4d80-a14a-b3647ff976d7', E'8df1e92f-a1eb-454f-972f-69e37e11d238', E'При атрофии уменьшаются размеры клеток и нередко их количество, что приводит к уменьшению органа и снижению функции. В длительно атрофированных клетках может накапливаться липофусцин в остаточных тельцах. Увеличение размеров клеток характерно для гипертрофии; гранулёмы связаны с определёнными воспалительными реакциями, а замещение паренхимы хрящом не является типичным признаком атрофии.'),
  (E'f22a4661-584a-4b2d-9a1e-2c456316a984', E'56f53c03-8f35-46d1-b87c-3f767215f980', E'Организация — врастание грануляционной ткани в некротический очаг, тромб или экссудат с последующим замещением соединительной тканью. Капилляры обеспечивают снабжение, а фибробласты синтезируют матрикс. Реституция восстанавливает исходную ткань, гипертрофия увеличивает клетки, а простой лизис без клеточного врастания не соответствует организации.'),
  (E'b091caad-50c8-43ff-a3f5-66e9424f40c7', E'ca60cc89-1372-418a-ab6b-4858cb66c4eb', E'При ложной гипертрофии внешний объём мышцы возрастает за счёт жировой и соединительной ткани, тогда как функциональные мышечные волокна атрофируются. При истинной рабочей гипертрофии увеличивается диаметр волокон за счёт наращивания сократительных структур. Увеличение числа зрелых скелетных мышечных волокон путём митоза не является обычным механизмом; викарная гипертрофия относится к парным органам после утраты второго.'),
  (E'f5c1c0f0-5743-42e2-98c3-2fde2c8d6496', E'26067337-7b1f-429c-9367-3bd256951c61', E'Стеноз почечной артерии хронически уменьшает поступление крови, кислорода и питательных веществ, что ведёт к ишемическому повреждению и постепенному уменьшению почки. Давление извне вызывает компрессионную атрофию, иммобилизация — дисфункциональную, а недостаток гормонального сигнала — дисгормональную. Эти причины важно различать, поскольку они указывают на разные механизмы повреждения.'),
  (E'd0f34ea9-a8c8-4599-ab5d-d494568404b5', E'c006f05e-d76f-4224-ac7f-2c6d6f0646fd', E'Фибробласты синтезируют коллаген и другие компоненты внеклеточного матрикса; миофибробласты дополнительно обладают сократительными свойствами и способствуют стягиванию раны. Эпителиоциты восстанавливают покровную поверхность, но не формируют основную массу глубокого рубца. Нейтрофилы участвуют преимущественно во воспалительном очищении, а зрелые эритроциты не синтезируют матрикс.'),
  (E'a1feb048-1f71-44ac-b79b-ba504a5077a7', E'869e689b-ab50-489c-ae18-71ec96a7095c', E'Стойкий незаживающий дефект указывает на гипорегенерацию, а избыточная грануляция или патологическое рубцевание — на чрезмерное либо нарушенное восстановление. Снижение сосудистости и уплотнение матрикса при созревании рубца — нормальная репаративная динамика. Своевременная эпителизация и восстановление при сохранном каркасе являются благоприятными признаками.'),
  (E'408ca301-b7a8-4727-a78e-b45922956989', E'47231f36-e8b7-46aa-a405-6bf8cfafff5e', E'Гиперплазия — увеличение числа клеток, что и происходит при пролиферации железистого эпителия эндометрия. При гипертрофии увеличивается размер клеток, а не их число. Метаплазия меняет зрелый клеточный тип; атрофия сопровождается уменьшением размеров клеток и/или их количества. Для корректной морфологической оценки важно различать число клеток и размер каждой клетки.'),
  (E'8536da9b-ec01-4f2e-a105-83ac1a53911b', E'b8be7188-e3b6-4e1d-8d23-ea6eff08a611', E'В тканях с низкой регенераторной способностью, включая миокард, погибшая паренхима не восполняется в достаточном объёме исходными клетками. Очаг очищается, прорастает грануляционной тканью и замещается рубцом, что сохраняет целостность, но может стойко снижать функцию. Полная реституция и превращение фибробластов в функциональные паренхиматозные клетки не являются типичными исходами; жировое замещение без фиброза не обязательно.'),
  (E'3f171061-872a-414d-9fc7-f58a5eb226cd', E'6275d786-89c9-4fbb-8da0-b1646baaf709', E'После резекции печени сохранившиеся гепатоциты входят в клеточный цикл и пролиферируют, увеличивая число клеток и восстанавливая массу органа; это компенсаторная гиперплазия. Изолированное увеличение размера клеток не отражает главного механизма восстановления. Организация инфаркта формирует рубец, а атрофия после иммобилизации связана со снижением нагрузки и не обеспечивает восстановление печени.'),
  (E'c5bea212-de3a-473b-b2c1-ed0d31fd66e1', E'b80745ef-6084-4692-98c9-3edd4a671af4', E'К основным адаптивным изменениям относят гипертрофию (увеличение размера клеток), гиперплазию (увеличение их числа), атрофию (уменьшение клеточного объёма и/или количества) и метаплазию (замену одного зрелого клеточного типа другим). Некроз и апоптоз — формы клеточной гибели, тромбоз и эмболия — сосудистые процессы. Организация и реканализация имеют другие механизмы, а экссудация, кровоизлияние, кальциноз и гиалиноз не составляют базовый набор адаптивных клеточных изменений.'),
  (E'63a64097-b754-4c5d-b1d5-5aa03f0a9929', E'0c3ed122-589b-465a-a11f-fdf243d4c832', E'Склероз обусловлен избыточным накоплением внеклеточного матрикса, главным образом коллагена, и замещением части паренхимы соединительной тканью. Он часто развивается после хронического воспаления, ишемии или повторного повреждения и может деформировать орган, снижая его функцию. Полная реституция не сопровождается таким замещением; отёк означает накопление жидкости, а увеличение числа эритроцитов не определяет тканевой склероз.'),
  (E'dce006bf-13a0-49c7-ae03-0295745daae5', E'19643994-fb07-462e-a728-c0a5973fade6', E'При хроническом повторном повреждении постоянная гибель клеток и репарация стимулируют фибробласты и накопление коллагена. Если повреждение сохраняется или регенераторный потенциал ограничен, развивается фиброз/склероз, нарушается архитектоника и возможна деформация органа. Полная реституция независимо от объёма повреждения не гарантирована; ложная гипертрофия не обязательна, а фибробласты участвуют в синтезе и созревании матрикса, а не исчезают мгновенно.'),
  (E'41c373dc-45d4-4e4e-a016-088646687b7f', E'80ff4bcc-1b98-4a8c-ba8d-d34c2c2ea67c', E'Водянкой серозной полости называют накопление в ней транссудата, например в плевральной или брюшной полости. Такая жидкость образуется при нарушении обмена и оттока, а не вследствие гнойного воспаления. Скопление крови в суставе называется гемартрозом и отличается от водянки составом содержимого и местом накопления. Разрастание соединительной ткани представляет собой тканевое изменение, а не скопление жидкости в полости. Примеры водянки включают гидроторакс в плевральной полости, асцит в брюшной полости и гидроперикард в полости перикарда. Термин зависит от локализации жидкости, тогда как слово «транссудат» характеризует её свойства. При воспалении серозных оболочек чаще образуется экссудат, поэтому характер содержимого помогает различить невоспалительный и воспалительный процессы.'),
  (E'6eaa174d-2bbf-4571-989c-8bfb05510380', E'b27c5135-d568-4c56-b511-218db9e1d9af', E'Лимфедема возникает, когда лимфатические сосуды не могут отводить достаточное количество жидкости и белков из тканей. Жидкость задерживается, участок тела увеличивается в объёме, а при длительном лимфостазе постепенно разрастается соединительная ткань и кожа может уплотняться. Если тканевая жидкость вообще не образовывалась бы, накапливаться было бы нечему. Гемолиз сам по себе не является единственной причиной лимфедемы, а снижение артериального притока не объясняет нарушение лимфатического оттока. Лимфатическая система в норме возвращает в кровоток избыток тканевой жидкости и белков. При её обструкции белок задерживается в интерстиции, поддерживает приток воды и вызывает хроническое воспаление с фиброзом. Поэтому длительная лимфедема может становиться плотной и стойкой, а также повышает риск повреждения кожи и присоединения инфекции.'),
  (E'ee233422-707a-4595-b724-a40340dba071', E'248d33f7-38ab-4823-94ce-325648c439e3', E'Грудной проток отводит значительную часть лимфы, в том числе богатую жирами лимфу из кишечника. При его повреждении лимфа может попадать в плевральную полость, и такое скопление называют хилотораксом. Гемоперикард означает скопление крови в полости перикарда, а гемартроз — крови в суставе. Гидроцефалия связана с избыточным накоплением спинномозговой жидкости в желудочковой системе мозга, поэтому эти состояния не являются последствием попадания лимфы в плевральную полость. Хилоторакс особенно важен потому, что с лимфой теряются жиры и белки, а при длительном процессе может нарушаться питание и иммунная защита. Внешний вид жидкости часто бывает молочно-белым из-за содержания хиломикронов, однако окончательно природу выпота определяют по его составу. Это отличает хилоторакс от кровяного или обычного серозного выпота.'),
  (E'f2ef5a6a-09b9-4764-8847-82e2d6912f2d', E'6de0312d-ce78-4c53-9803-ac96c7ab9125', E'Артериальная гиперемия развивается при усиленном притоке крови по артериям, поэтому ткань обычно становится более красной и тёплой. При венозном полнокровии основная проблема — затруднённый отток крови; ткань переполняется кровью, приобретает синюшный оттенок и может отекать. Тромбоз артерии скорее препятствует притоку и не является общей причиной обоих состояний. Венозная кровь содержит меньше кислорода, а артериальная гиперемия не обязательно заканчивается некрозом. Артериальная гиперемия обычно сопровождается усилением притока насыщенной кислородом крови, тогда как венозный застой связан с задержкой крови и снижением насыщения тканей кислородом. Поэтому при венозном полнокровии возможны цианоз, отёк и при длительном течении дистрофические изменения. Эти процессы различаются прежде всего направлением изменения кровотока — приток усиливается или отток затрудняется.'),
  (E'352bbc63-379f-4fe3-9bbf-45b2cedcde5d', E'b5cfafbf-2dbc-452f-9673-e1b66525b9fa', E'При остром венозном застое кровь задерживается в венулах и капиллярах, а повышенное внутрисосудистое давление способствует выходу жидкости в ткани. Поэтому орган или участок ткани обычно выглядит полнокровным, синюшным и нередко отёчным. Бледность и малокровие характернее для недостаточного кровенаполнения. Рубцевание требует длительного повреждения и разрастания соединительной ткани, а ярко-красный цвет чаще связан с усиленным артериальным притоком, а не с венозным застоем. Если венозный застой сохраняется, гипоксия повреждает паренхиматозные клетки и способствует развитию дистрофии и склероза. При остром застое изменения могут быть обратимыми после восстановления оттока, тогда как хроническое нарушение оставляет более стойкие последствия. Выраженность отёка зависит от степени повышения внутрисосудистого давления и состояния сосудистой стенки.'),
  (E'b895e7df-ec0d-46a9-bec8-d2b29bb7cde2', E'1af6331a-7e91-40e9-8bb8-cc35bf726747', E'Скопление крови в плевральной полости называется гемотораксом. Кровь занимает пространство вокруг лёгкого и может сдавливать его, затрудняя дыхание; при значительной кровопотере дополнительно развивается гиповолемия. Гемоперитонеум означает кровь в брюшной полости, гемоперикард — кровь в полости перикарда, а гемартроз — кровь в суставе. Эти термины обозначают похожие по природе процессы, но различаются по месту, где скапливается кровь. Внутримозговая гематома может разрушать проводящие пути и вызывать очаговые неврологические симптомы в зависимости от расположения. Дополнительный отёк вокруг очага увеличивает объём поражения и усиливает давление на окружающую ткань. Поэтому при оценке тяжести учитывают не только объём крови, но и локализацию, скорость развития и состояние внутричерепных структур.'),
  (E'925851f3-d499-4182-b127-1574ac09aef0', E'1bb584e3-cb55-423e-802f-882df53010cd', E'Опасность кровоизлияния в головной мозг определяется прежде всего его объёмом и расположением. Кровь повреждает нервную ткань, а образовавшийся очаг может сдавливать соседние структуры и повышать внутричерепное давление. Даже сравнительно небольшой очаг в жизненно важной области способен вызвать тяжёлые нарушения. Цвет крови сам по себе не определяет тяжесть, наружная рана не обязательна при внутричерепном кровоизлиянии, а количество лимфы вокруг очага не является главным фактором риска. После рассасывания крови макрофаги удаляют клеточные остатки, а в очаге могут оставаться гемосидерин и другие продукты распада гемоглобина. При крупных кровоизлияниях организация приводит к замещению части повреждённой ткани соединительной тканью. Конкретный исход зависит от размера очага, локализации, кровоснабжения и наличия осложнений, в том числе инфекции.'),
  (E'83311761-c9e8-4aa3-b50e-cb559c13d932', E'487f10d7-05b3-4e2a-983b-ede61c8482c4', E'При благоприятном течении небольшое кровоизлияние может постепенно рассосаться: компоненты крови разрушаются и удаляются клетками. Более крупный очаг может подвергаться организации — в нём разрастается соединительная ткань, иногда формируется полость или капсула. Нагноение возможно при присоединении инфекции, но не является обязательным исходом. Амилоидоз не представляет собой обычный результат рассасывания крови, а постоянное увеличение очага не происходит независимо от причины и состояния сосудов. Клинически геморрагический диатез может проявляться кровоточивостью дёсен и носа, петехиями, синяками или более глубокими кровоизлияниями. Тип проявлений частично зависит от того, нарушено ли первичное тромбоцитарное звено гемостаза или плазменные факторы свёртывания. Поэтому термин объединяет разные заболевания, для которых общим признаком является повышенная кровоточивость.'),
  (E'4b653848-c6fa-4409-ae4e-56dcf7a035a3', E'e531cc5d-a8d5-4fca-986c-32c23b22522f', E'Геморрагический диатез — это повышенная склонность к кровотечениям и кровоизлияниям. Она может быть связана с повреждением сосудистой стенки, уменьшением числа или нарушением функции тромбоцитов либо дефицитом факторов свёртывания. Артериальная гипертензия сама по себе не определяет геморрагический диатез, а увеличение числа эритроцитов при сохранном гемостазе не означает повышенную кровоточивость. Скопление транссудата в серозной полости относится к отёкам и водянкам, а не к нарушениям гемостаза. При тромбоцитопении чаще возникают поверхностные кровоизлияния и кровоточивость слизистых, поскольку нарушается образование первичной тромбоцитарной пробки. При дефекте факторов свёртывания чаще возможны более глубокие кровоизлияния и кровотечения после травм. Такое различие связано с функциями двух звеньев гемостаза и помогает понять, почему изменение числа тромбоцитов имеет характерные проявления.'),
  (E'2783194f-14d0-4114-a9cf-97524b9ca403', E'82878e3e-65ff-4abf-8f45-67b8665e621a', E'Септический шок развивается при тяжёлой инфекции и системной воспалительной реакции. Воспалительные медиаторы нарушают сосудистый тонус и функцию эндотелия, меняют микроциркуляцию и ухудшают доставку кислорода к тканям; возможно повреждение нескольких органов и развитие ДВС-синдрома. Сдавление одной крупной вены вызывает локальное нарушение венозного оттока, а накопление амилоида в миокарде относится к другому патологическому процессу. Массивная кровопотеря характерна для гиповолемического, а не для обязательного механизма септического шока. При морфологической оценке важно сопоставлять изменения в разных органах с причиной и стадией процесса: отдельный признак редко позволяет судить о тяжести состояния без учёта общей картины.'),
  (E'239eb57a-f8e8-418e-bd78-5212112f764a', E'88c49025-e77a-4a58-b005-3603fba38f45', E'При тяжёлом шоке кровоток через почки снижается, и канальцевый эпителий получает недостаточно кислорода. Ишемия может вызвать острое повреждение канальцев и привести к уменьшению выделения мочи и ухудшению функции почек. Увеличение числа нефронов не является типичным быстрым ответом на шок, а амилоид в лоханке не объясняет острое ишемическое повреждение. При выраженной и длительной гипоперфузии морфологические изменения возможны, поэтому утверждение об их полном отсутствии неверно. Таким образом, основное значение имеет связь между нарушением кровообращения, тканевой гипоксией и структурными изменениями органов. Эта последовательность объясняет как клинические проявления, так и возможные осложнения процесса.'),
  (E'0464d2a6-d87d-46d0-b353-8f587bfd5c0b', E'1cdd9d17-b512-41d5-97e1-71621503a0a2', E'Различие между крупозным и дифтеритическим воспалением связано прежде всего с глубиной повреждения и некроза, а также с особенностями ткани. При поверхностном некрозе фибринозные массы лежат поверхностно; при глубоком некрозе они пропитывают ткань и прочно фиксируются. Количество эритроцитов может влиять на геморрагический компонент, но не определяет тип фибринозного воспаления. Возраст и соседние лимфатические узлы также не являются главными критериями этой морфологической классификации.'),
  (E'afd63cf0-739c-4dc5-b074-27e5b41d2432', E'56cb154d-ad94-41b1-877d-895e1d304c44', E'Фибринозные плёнки в гортани в сочетании с воспалительным отёком могут резко сузить просвет дыхательных путей и вызвать удушье. Опасность определяется локализацией и объёмом наложений, а не только их морфологическим типом. Амилоидоз не является закономерным непосредственным осложнением острого фибринозного воспаления; жировая дистрофия миокарда и серозный выпот в суставе не объясняют риск острой обструкции дыхательных путей.'),
  (E'a78d3f32-3fcd-45fa-a57d-a0c93e2cdffe', E'4eaafae9-3ee2-4e1d-ba06-af811c66bc75', E'Гной представляет собой густой экссудат, в котором обычно много нейтрофилов, погибших клеток, тканевого детрита и нередко микроорганизмов. Ферменты нейтрофилов и другие механизмы повреждения способствуют расплавлению ткани. Фибриновые нити преобладают при фибринозном воспалении, эритроциты — при геморрагическом компоненте, а лимфоциты и плазматические клетки более типичны для ряда хронических воспалительных реакций.'),
  (E'68512e93-cfbb-42f4-93ef-355d3250fe31', E'b60a4f90-593d-4387-97f3-e1ac17c805d1', E'Абсцесс формируется при локальном гнойном расплавлении ткани с образованием полости, содержащей гной. По периферии развивается воспалительная реакция, а при дальнейшем течении может сформироваться пиогенная мембрана и затем рубцовая ткань. Диффузное распространение гноя в клетчатке называют флегмоной. Гной в существующей полости, например плевральной, обозначают термином «эмпиема». Серозное содержимое под эпидермисом не соответствует абсцессу.'),
  (E'555a0746-4c91-41e9-8642-c11eb5c4699b', E'a15465fa-802c-4025-a064-4d4b7fdc82eb', E'Воспаление представляет собой сложную типовую реакцию живой ткани на повреждение, в которой участвуют микроциркуляторное русло, клетки крови и соединительной ткани, а также медиаторы. Её задача — локализовать и устранить повреждающий фактор и создать условия для восстановления. Увеличение числа клеток само по себе не определяет воспаление; кровоизлияние является лишь возможным компонентом некоторых форм; иммунные механизмы важны, но воспаление не сводится только к ним.'),
  (E'49a2c3cd-c224-4b7f-ba07-70a59919933b', E'dbf4f789-5452-4657-940f-18d8a3c8aa7d', E'Классификация по преобладающему компоненту отражает характер экссудата и позволяет выделять серозное, фибринозное, гнойное, геморрагическое и катаральное воспаление. В клинической морфологии также рассматривают смешанные варианты. Острый и хронический типы описывают течение, а очаговое и диффузное — распространённость процесса. Деление на первичное, вторичное и третичное не является стандартной классификацией воспаления по преобладающему компоненту.'),
  (E'63c2b95e-58fa-4b11-a0bb-c576e6dd5b90', E'e9027f43-4896-4410-ad7e-d96ece697f5e', E'Течение отражает длительность и динамику процесса: выделяют острое, подострое и хроническое воспаление. Распространённость показывает, ограничен ли процесс отдельным очагом или охватывает значительную часть ткани либо органа, поэтому говорят об очаговом и диффузном вариантах. Серозное, гнойное, фибринозное и катаральное обозначают морфологические формы по характеру экссудата, а местное и общее характеризуют уровень проявления процесса.'),
  (E'f15f9045-1b8f-4f43-8c42-01b43e1a0c4e', E'a1d610d3-23b6-4f47-a4fc-2619225b1928', E'При серозном воспалении образуется жидкий, обычно прозрачный или слегка мутный экссудат с относительно невысоким содержанием белка и ограниченным количеством клеток. Он может скапливаться в серозных полостях, тканях или пузырях эпидермиса. Гнойное воспаление сопровождается большим количеством нейтрофилов и расплавлением тканей; фибринозное — выпадением фибрина; геморрагическое отличается значительной примесью эритроцитов.'),
  (E'b3d001ad-ee9e-4ab5-9a21-882dd9048d9a', E'a4da5951-61fc-43b2-944b-5ebb93398908', E'При благоприятном течении серозный экссудат постепенно резорбируется, а повреждённые клетки восстанавливаются или заменяются без значимого рубца. Если экссудат сохраняется длительно либо повреждение выражено, возможно разрастание соединительной ткани и уплотнение участка. Абсцесс требует гнойного воспаления, фибринозная форма не является обязательной стадией серозной, а распространённый некроз — возможное осложнение тяжёлого повреждения, но не типичный исход.'),
  (E'dc70bec6-e9da-45a1-9996-d5c77aefa539', E'2fded867-d1f1-4203-b3ff-dd68e4810266', E'При повышении сосудистой проницаемости фибриноген выходит из плазмы в очаг воспаления и превращается в фибрин, формируя нити и наложения на поверхности или в ткани. Именно фибрин придаёт экссудату характерный вид. Прозрачная малобелковая жидкость соответствует серозному воспалению; пролиферация фибробластов относится к репарации и организации; скопление эритроцитов характерно для геморрагического компонента.'),
  (E'bcca9260-ca21-4f9c-812b-e1448e24e8f4', E'8f064100-012e-4c9b-bf34-1a0709af4593', E'При крупозном воспалении фибринозные массы лежат преимущественно на поверхности слизистой или серозной оболочки и обычно снимаются относительно легко, оставляя поверхность без глубокого дефекта либо с небольшим повреждением. При дифтеритическом воспалении некроз захватывает более глубокие слои, поэтому плёнка прочно связана с тканью и после её отделения остаётся дефект. Гнойная полость характерна для абсцесса, а слизистое покрытие — для катарального воспаления.'),
  (E'a335d01f-6158-41fa-8bcc-8542022a7f67', E'f2590215-45e0-4353-8072-2a64e0c89b4a', E'Дифтеритическое воспаление развивается при глубоком повреждении ткани: фибрин пропитывает некротизированные слои, и образующаяся плёнка тесно связана с подлежащими тканями. При её отделении обычно остаётся язвенный дефект, иногда с кровоточивостью. Легко снимающаяся поверхностная плёнка типична для крупозного воспаления. Серозная жидкость и слизистый экссудат относятся к другим морфологическим формам и не объясняют прочного прикрепления плёнки.'),
  (E'71626e9a-92ed-41e0-902d-b4b945f6ba36', E'059eeb85-6f28-4c11-bbf1-834c2b165f90', E'Рубец формируется, если повреждение сопровождается утратой значительного объёма клеток и тканевого каркаса, которые невозможно полностью восстановить. В этом случае дефект заполняется грануляционной тканью, затем созревает соединительная ткань. Небольшой серозный выпот обычно резорбируется без рубца, катаральное воспаление не обязательно оставляет рубцы, а обратимые сосудистые изменения сами по себе не требуют фиброзного замещения.'),
  (E'd056ee91-31d7-41d6-83a7-9cbdcbcf9f5d', E'b853d2d2-c5a8-4dff-8ae0-eaa4a24c339b', E'Инфекция поддерживает воспаление и разрушение ткани; ишемия ограничивает доставку кислорода; диабет нарушает микроциркуляцию и функции иммунных клеток; недостаточное питание ограничивает синтез белков матрикса; некроз препятствует формированию здоровой грануляционной ткани. Напротив, адекватное кровоснабжение, чистые края, сохранный каркас и удаление некротических масс при контроле инфекции способствуют заживлению.'),
  (E'5de3a7a1-c24c-457f-8af4-d5d11fa13735', E'b3d9cc93-b8f6-4403-9945-f5eaead288d1', E'Классификация по биологическому значению включает физиологическую, репаративную и патологическую регенерацию. Деление на клеточную и внутриклеточную относится к механизму; реституция и субституция характеризуют результат восстановления; ишемическая, компрессионная и дисгормональная — виды атрофии по причине. Смешение этих классификационных оснований приводит к ошибкам в интерпретации морфологического процесса.');
INSERT INTO public.question_answers (question_id, correct_option_id, explanation) VALUES
  (E'2c3f5433-1a22-424d-9968-3fc735e23754', E'e5852a36-8433-4b81-8f3f-5c5ffbdf22ff', E'Транссудат образуется не из-за воспаления, а при нарушении равновесия между гидростатическим и онкотическим давлением либо при затруднении оттока жидкости. Поэтому в нём обычно меньше белка и клеток, чем в экссудате. Воспалительная жидкость с большим количеством белка и клеток — это экссудат. Кровь, вышедшая в ткань, образует кровоизлияние, а богатая жиром лимфа отличается составом и связана с повреждением лимфатических путей. При оценке жидкости важно учитывать не только место её скопления, но и состав: малое содержание белка характерно для транссудата, тогда как воспалительное повышение сосудистой проницаемости приводит к образованию экссудата. Эти различия помогают установить механизм отёка и отличить его от кровоизлияния или скопления лимфы.'),
  (E'2620d3d9-ec08-44da-bb97-61877b04ddaa', E'd005ab57-b1f8-43bb-a2df-e396ffb1c47b', E'При сердечной недостаточности кровь хуже оттекает по венам, и давление в венозном отделе капилляров повышается. Из-за этого больше жидкости переходит из сосудов в межклеточное пространство и развивается отёк. Снижение капиллярного давления уменьшало бы фильтрацию. Альбумин удерживает воду в сосудистом русле, поэтому усиление его синтеза не объясняет этот механизм. Полного прекращения фильтрации при венозном застое не происходит. При этом отёк формируется тогда, когда фильтрация жидкости превышает возможности её обратного всасывания и лимфатического дренажа. При сердечной недостаточности венозное давление повышается, а при снижении концентрации альбумина уменьшается онкотическое давление плазмы; оба механизма могут способствовать выходу жидкости в ткани.'),
  (E'e7cdeeac-6335-45dc-9248-cb67850b49f3', E'8f0537cf-67b9-423a-a961-23def6dfd167', E'При отёке лёгких жидкость сначала накапливается в интерстициальной ткани, а при нарастании процесса проникает в альвеолы и затрудняет газообмен. Лёгкие становятся тяжёлыми, влажными, при надавливании с поверхности разреза может выделяться пенистая жидкость. Сухие альвеолы и уменьшение массы лёгких этому не соответствуют. Расширение бронхов само по себе не означает отёка, а амилоид в альвеолярных стенках не является его типичной причиной. На раннем этапе жидкость находится преимущественно между структурами лёгочной ткани, а при дальнейшем накоплении заполняет альвеолярные пространства. Из-за этого уменьшается эффективная поверхность газообмена и возникает гипоксия. Пенистый характер содержимого связан с перемешиванием жидкости с воздухом при дыхательных движениях.'),
  (E'953e4d0d-a7fa-4da8-a309-c02aa644ab72', E'0572f814-55b9-45c3-8916-df4901ba39da', E'Черепная коробка почти не может расширяться, поэтому накопление жидкости в ткани мозга увеличивает внутричерепное давление. Это ухудшает кровоснабжение мозга и при тяжёлом отёке может привести к смещению и сдавлению жизненно важных отделов. Отёк не означает, что обязательно возникнет массивное кровоизлияние или гнойное воспаление: для них нужны другие механизмы. Снижения внутричерепного давления также не происходит — оно, напротив, может повышаться. Отёчная ткань мозга увеличивается в объёме, сглаживает извилины и может сдавливать желудочки. Если давление становится критическим, возможно смещение мозговых структур и сдавление ствола мозга, где расположены жизненно важные центры. Поэтому выраженный церебральный отёк опасен не только повреждением нервных клеток, но и нарушением работы дыхательной и сердечно-сосудистой систем.'),
  (E'a31c1e7e-a759-4208-8ec4-40a5c55d0e22', E'751d6aac-c818-4c20-b66b-1bcea4097978', E'Мукоидное набухание часто возникает в стенках артерий и клапанах сердца; оно также может затрагивать эндокард, эпикард и капсулы суставов. При микроскопии основное вещество выглядит разрыхлённым и лучше связывает основные красители вследствие накопления кислых гликозаминогликанов. Эпителий почечных канальцев и нейроны не являются типичными местами стромального мукоидного набухания; подкожная жировая клетчатка также не относится к его характерным локализациям. Чаще поражаются соединительная ткань сосудистых стенок и клапанов сердца. Изменения выявляют прежде всего в соединительнотканных структурах, а не внутри специализированных клеток. При микроскопии могут отмечаться разрыхление основного вещества и изменение его тинкториальных свойств; эти признаки сами по себе не означают некроз или отложение амилоида. При дифференциальной оценке важно учитывать и локализацию, и глубину повреждения.'),
  (E'771afc28-0cac-41ee-be56-062e09b7064f', E'2063fad5-86ee-419e-b993-f600be13a555', E'Фибриноидное набухание может прогрессировать до фибриноидного некроза; в дальнейшем в очаге возможно развитие гиалиноза и склероза. При некрозе разрушаются элементы соединительной ткани и клетки, а при организации очага может формироваться плотная соединительная ткань. Полное восстановление во всех случаях неверно, поскольку глубокое повреждение может завершиться некрозом и склерозом; жировая киста печени и гидропическая дистрофия не являются типичными исходами фибриноидного набухания. Такой исход особенно вероятен при выраженном иммунном или сосудистом повреждении. Фибриноидный некроз означает необратимое разрушение ткани в очаге, а последующая организация может приводить к склерозу и гиалинозу. Исход зависит от причины, интенсивности и длительности повреждения, поэтому считать процесс всегда обратимым нельзя.'),
  (E'6f28a422-a177-43c0-8d6f-41f9cf127085', E'bba954f4-a027-4c5d-b7b2-ad149dbae5e7', E'При длительном венозном застое в лёгких эритроциты могут выходить из переполненных капилляров в альвеолы и разрушаться. Макрофаги поглощают продукты распада гемоглобина, накапливая гемосидерин, а хроническое повреждение сопровождается разрастанием соединительной ткани. Сочетание гемосидероза и склероза придаёт лёгким бурый цвет и плотность — так формируется бурая индурация. Изолированная жировая дистрофия, казеозный некроз или исчезновение капилляров без пигмента не объясняют эту характерную картину. Гемосидерин представляет собой железосодержащий пигмент, образующийся при распаде гемоглобина. Его накопление в макрофагах указывает на повторный или длительный выход эритроцитов в ткань. Одновременно склероз перегородок снижает эластичность лёгких и ухудшает их функцию, поэтому бурая индурация отражает и пигментацию, и хроническое уплотнение органа.'),
  (E'172e481c-e541-42e8-81c3-4c2e6c7254b7', E'0236a7e6-9bf9-48c6-b1d7-ce35326f6212', E'При хроническом застое в лёгких эритроциты выходят в альвеолы и распадаются. Альвеолярные макрофаги поглощают гемоглобин и накапливают образующийся из него гемосидерин; такие клетки называют клетками сердечных пороков. Нейтрофилы не синтезируют меланин, а эпителиоциты не превращаются в адипоциты в рамках этого процесса. Фибробласты участвуют в образовании соединительной ткани, но поглощение амилоида не объясняет появление характерных пигментированных макрофагов. Такие макрофаги являются морфологическим свидетельством предшествующего выхода эритроцитов в альвеолы и их последующего распада. Их обнаружение особенно характерно для хронического застоя в малом круге кровообращения, например при левожелудочковой недостаточности. При этом сами клетки не вызывают застой, а отражают его длительное существование и последствия для лёгочной ткани.'),
  (E'70ee3ec7-7252-44c8-83f9-50a68dbfec7a', E'd8454498-de18-4060-8f6e-8262f4cfee5f', E'Бурая индурация лёгких возникает при длительном венозном застое. Из-за выхода эритроцитов и распада гемоглобина в ткани накапливается гемосидерин, а хроническая гипоксия и повреждение стимулируют склероз межальвеолярных перегородок. Пигмент придаёт лёгким буроватый оттенок, а разрастание соединительной ткани делает их более плотными. Кальцификация, гнойное расплавление и накопление жира в бронхах не являются основой этого сочетания морфологических изменений. На разрезе застойные изменения распределяются неравномерно: центральные зоны долек полнокровны и темнее, а периферические участки могут выглядеть светлее из-за жировой дистрофии гепатоцитов. Именно сочетание этих зон формирует характерную пёструю картину. При длительном застое возможны атрофия клеток в центральных отделах и разрастание соединительной ткани.'),
  (E'c66cd57a-08b9-4d3c-8680-c8bc4c588b7d', E'5a6df8c8-9639-407a-b349-f2cfae7ff774', E'При хроническом венозном застое печени кровь преимущественно скапливается в центральных отделах долек, где гепатоциты могут испытывать гипоксию и повреждаться. Периферические участки долек выглядят относительно светлее, поэтому на разрезе возникает пёстрый рисунок, напоминающий мускатный орех. Равномерная бледность не отражает такого распределения полнокровия. Лимфатические полости и фибринозные плёнки не являются характерными признаками застойной печени и связаны с другими патологическими процессами. Помимо отёков и асцита, системный венозный застой может сопровождаться увеличением печени, цианозом и застойными изменениями других органов. Морфологическая картина зависит от длительности и выраженности недостаточности кровообращения. В отличие от локальной гиперемии, здесь нарушен отток по большому кругу в целом, поэтому изменения имеют системный характер.'),
  (E'63451ceb-d0f3-44c7-8a13-3fabd5d3ce10', E'3e83dc57-caf1-4dd3-8f01-d4cfeffc8a9b', E'Правожелудочковая сердечная недостаточность затрудняет продвижение крови из системных вен к сердцу. Давление в венозной системе большого круга повышается, поэтому кровь застаивается в печени и других органах, а жидкость выходит в ткани и полости, вызывая отёки и асцит. Усиленная работа левого желудочка при сохранном венозном оттоке не объясняет системный застой. Острая гиперемия кожи локальна, а усиление лимфообразования само по себе не заменяет нарушения венозного оттока. При асците жидкость растягивает брюшную стенку и может смещать диафрагму вверх, затрудняя дыхательные движения. При портальной гипертензии его развитию способствуют повышение гидростатического давления в портальной системе и задержка натрия и воды. По характеру содержимого асцит отличается от гемоперитонеума, при котором в брюшной полости находится кровь.'),
  (E'152e3a5d-f0c7-42a3-835c-426a975d8d3f', E'3e77157f-e5a4-44d6-bfc0-1c069abfc5db', E'Скопление транссудата в брюшной полости называется асцитом. Он может развиваться, в частности, при портальной гипертензии, когда повышается давление в системе воротной вены, а также при сердечной недостаточности и других состояниях. Гидроторакс означает накопление жидкости в плевральной полости, гемоперикард — крови в перикарде, а гидроцефалия — избыточное накопление спинномозговой жидкости в желудочках мозга. Названия различаются прежде всего по содержимому и анатомической полости. Расширенные портокавальные анастомозы возникают потому, что кровь ищет обходные пути при затруднённом прохождении через печень. Варикозно расширенные вены пищевода имеют тонкую стенку и могут разрываться, вызывая массивное кровотечение. Увеличение селезёнки связано с длительным венозным полнокровием, а асцит — с повышенным давлением и изменением водно-солевого обмена.'),
  (E'83c56849-de85-4563-b888-c952b1de33b2', E'7954e3bd-6739-419e-bbec-0926cac83e5a', E'При портальной гипертензии повышается давление в системе воротной вены. Это способствует выходу жидкости в брюшную полость и развитию асцита, затрудняет венозный отток от селезёнки и вызывает её увеличение. Также расширяются портокавальные анастомозы, в том числе в области пищевода; их стенки могут быть источником опасного кровотечения. Отёк мозга и сужение вен пищевода не составляют типичной картины, а атрофия селезёнки противоречит застойному увеличению. Изолированная артериальная гиперемия кишечника не объясняет эти признаки. При хроническом застое селезёнка может становиться плотнее из-за разрастания соединительной ткани и отложения пигмента, а её функция иногда нарушается. Это состояние следует отличать от инфаркта селезёнки, который возникает при прекращении или резком уменьшении притока крови. При застое же кровь поступает, но затруднён её отток, поэтому орган переполняется кровью.'),
  (E'51a975dd-e561-4780-9af2-217d28bb28db', E'3a41a002-d9b6-47dc-a995-a6fa17f5b0f0', E'При длительном повышении давления в венозной системе селезёнки кровь задерживается в её сосудистом русле, орган увеличивается и становится полнокровным. Такой механизм лежит в основе застойной спленомегалии, которая может сопровождать портальную гипертензию. Прекращение артериального притока привело бы к ишемии, а не к венозному полнокровию. Воздух в пульпе не вызывает типичного застойного увеличения, а уменьшение числа лимфатических сосудов без венозных изменений не объясняет накопление крови в селезёнке. По локализации различают наружное кровотечение, когда кровь выходит за пределы тела, и внутреннее, когда она скапливается в тканях или полостях. Кровоизлияние обычно означает выход крови в ткань с формированием очага, например петехии, экхимоза или гематомы. Клиническая опасность зависит от объёма потери крови, скорости кровотечения и того, какой орган повреждён.'),
  (E'b86b4260-a9f2-4bbf-8cda-539fb8c9b06f', E'ff467d80-6f83-4398-b078-16359912a217', E'Кровотечением называют выход крови из сосудистого русла наружу либо в полости и ткани организма. Оно может возникать при повреждении сосуда, разрушении его стенки или нарушении гемостаза. Накопление лимфы в интерстиции представляет собой лимфедему, а увеличение количества эритроцитов внутри сосудов не означает, что кровь покинула сосудистое русло. Простое расширение капилляров также не является кровотечением, пока кровь не выходит за пределы сосудов. При аррозии сосуд повреждается постепенно по мере разрушения окружающих тканей, поэтому источник кровотечения может находиться в язве или распадающемся патологическом очаге. В отличие от травматического разрыва, здесь важен предшествующий патологический процесс, который разрушает сосудистую стенку. Объём кровопотери зависит от калибра сосуда и того, насколько полно нарушена его стенка.'),
  (E'92abe209-9f93-4c84-859a-fabbe806b728', E'8e8ab57c-15fb-4dbf-bc0b-00d8a8aaf399', E'Аррозивное кровотечение возникает, когда патологический процесс разрушает стенку сосуда. Такое повреждение возможно, например, при распаде опухоли, язвенном процессе или воспалительном разрушении тканей. Само по себе повышение числа тромбоцитов не означает разрушения сосудистой стенки. Обычное повреждение кожи может вызвать кровотечение, но термин «аррозивное» указывает именно на разрушение сосуда патологическим процессом. Выход лимфы из лимфатического сосуда называется лимфореей, а не кровотечением. Диапедезные кровоизлияния часто проявляются мелкими точечными очагами — петехиями, особенно при изменениях микроциркуляции или нарушениях гемостаза. При разрыве сосуда кровь выходит через дефект стенки, а при диапедезе проходит между элементами сосудистой стенки. Поэтому размер очага и механизм выхода эритроцитов помогают различать эти виды кровоизлияний.'),
  (E'bea7dafc-e6d0-4c0e-a96b-f4de443a8be2', E'cd9f6e1e-aa3d-4e15-b8c7-c9f2dda7aaf2', E'При диапедезном кровоизлиянии эритроциты проходят через стенку мелких сосудов без крупного разрыва сосуда. Такое явление возможно при повышении проницаемости сосудистой стенки и нарушениях микроциркуляции. Разрыв крупной артерии обычно приводит к более массивному кровотечению и может образовать гематому. Транссудат в плевральной полости представляет собой скопление жидкости, а отложение фибрина внутри сосуда связано со свёртыванием крови и само по себе не является выходом эритроцитов в ткань. Со временем кровь в гематоме свёртывается, затем подвергается ферментативному распаду и удаляется клетками. В зависимости от размера и локализации гематома может сдавливать соседние структуры и нарушать их функцию. При инфильтрации кровь распределяется между тканевыми элементами без выраженной полости, поэтому морфологически эти два вида кровоизлияния выглядят по-разному.'),
  (E'38abef5b-7ab5-46f2-aa82-f77507874d2d', E'db852e16-8db7-4a03-a2d4-95b4a57a6550', E'Гематома — это скопление крови, которое раздвигает ткани и формирует полость. При геморрагической инфильтрации кровь пропитывает тканевые элементы, но отдельная полость обычно не образуется. Поэтому различие заключается не в составе содержимого, а в характере его распределения в ткани. Лимфа и гной имеют другой состав, а гематома не обязательно бывает микроскопической: её размер зависит от объёма кровотечения. Морфологическое различие между гематомой и инфильтрацией принципиально важно. Даже если кровопотеря из плевральной полости не видна снаружи, она может быть значительной. Сдавление лёгкого уменьшает его расправление, а быстрое накопление крови способно вызвать дыхательную недостаточность и падение артериального давления. Для сравнения, при гемоперикарде особенно опасно сдавление сердца, поскольку нарушается наполнение его камер.'),
  (E'b5aeaad9-a52f-4c15-a87f-3417d354cfb6', E'7a64f4e2-26ff-496a-9980-1f9fa9d32654', E'Тромбоциты участвуют в первичном гемостазе: они прикрепляются к повреждённой сосудистой стенке и формируют первичную гемостатическую пробку. При снижении их числа этот механизм ослабевает, поэтому появляются петехии, пурпура и кровоточивость слизистых. Избыток альбумина не восстанавливает количество тромбоцитов. Усиление лимфатического оттока и образование коллагена в коже также не устраняют дефект первичного гемостаза и не объясняют типичную картину тромбоцитопенической пурпуры. ДВС-синдром развивается вторично при тяжёлых состояниях, например шоке, сепсисе или массивном повреждении тканей. Микротромбы нарушают кровоснабжение органов, а расходование компонентов свёртывания приводит к кровоточивости из мест повреждения и инвазивных вмешательств. Поэтому клиническая картина может одновременно включать признаки ишемического повреждения органов и множественные кровоизлияния.'),
  (E'56da18e9-c6d7-4c34-b002-7728425149d5', E'a205948a-9b7d-4123-b750-f6eaccc7b699', E'При ДВС-синдроме свёртывание крови системно активируется, и во множестве мелких сосудов образуются микротромбы. На их формирование расходуются тромбоциты и факторы свёртывания, поэтому по мере развития процесса гемостаз истощается и возникает кровоточивость. Таким образом, одновременно возможны нарушение микроциркуляции и кровоизлияния. Изолированная гипотензия не описывает этот механизм, тромбоз одной крупной артерии не является диссеминированным процессом, а увеличение объёма лимфы не связано с потреблением факторов свёртывания. По мере истощения тромбоцитов и факторов свёртывания кровотечение становится всё труднее остановить, а продукты распада фибрина могут дополнительно отражать активацию фибринолиза. Последовательность и выраженность фаз зависят от причины и тяжести ДВС-синдрома, поэтому у разных пациентов они не всегда имеют одинаковую продолжительность. Важно учитывать, что тромбоз и кровоточивость являются связанными проявлениями одного процесса.'),
  (E'dcb579d0-f766-4e10-b31d-27058020c329', E'dee7c01c-eaf9-4be9-ab39-45ca110c7b7c', E'В типичном развитии ДВС-синдрома сначала активируется свёртывание крови и формируются множественные микротромбы. Затем тромбоциты и факторы свёртывания расходуются, развивается коагулопатия потребления и повышается риск кровотечений. Поэтому процесс может начинаться с микротромбоза, а затем сопровождаться выраженной кровоточивостью. Гипокоагуляция без предшествующего микротромбообразования не отражает эту последовательность. Фиброз с лимфедемой и обязательный амилоидоз не относятся к основным этапам патогенеза ДВС-синдрома. Микротромбы повреждают не только почки, но и другие органы с развитой микроциркуляторной сетью. В почках нарушение кровотока может привести к острому повреждению канальцев и снижению фильтрационной функции. При тяжёлом течении уменьшается диурез, накапливаются продукты обмена и развивается острая почечная недостаточность; степень изменений определяется длительностью ишемии и тяжестью процесса.'),
  (E'32d2d32d-3c72-4fdb-98d0-47d08c71db88', E'bbad8164-0118-4c2e-84b8-3f8c7ca80aab', E'При ДВС-синдроме свёртывание крови активируется по всему сосудистому руслу, поэтому образуются множественные микротромбы. На их формирование расходуются тромбоциты и факторы свёртывания; когда их становится недостаточно, организм уже не может эффективно останавливать кровотечение. Этим объясняется сочетание тромбозов с кровоточивостью. Полное отсутствие активации свёртывания не привело бы к образованию микротромбов. Эритроциты не превращаются в лимфоциты, а одно лишь расширение сосудов не объясняет потребление компонентов гемостаза. В патологоанатомическом понимании шок — не просто кратковременная слабость или эмоциональная реакция, а критическое расстройство системного кровообращения. Независимо от первичной причины, недостаточная доставка кислорода приводит к переходу клеток на менее эффективный обмен веществ и повреждению мембран. Если перфузия не восстанавливается, изменения становятся необратимыми и могут завершиться полиорганной недостаточностью.'),
  (E'9dc686b7-93d0-460c-99f0-251a2bdd8984', E'92ec0545-2d50-4912-881a-1c8dc9d32c33', E'При ДВС-синдроме микротромбы могут закупоривать мелкие сосуды почек и нарушать кровоснабжение ткани. Недостаток кислорода вызывает ишемическое повреждение, а при тяжёлом процессе функция почек резко ухудшается. Жировая дистрофия эпителия лоханки не является характерным объяснением этого поражения, а лимфатические кисты не связаны с микротромбозом. Увеличение числа нефронов также не является типичным острым ответом почек на ДВС-синдром; важен именно ущерб микроциркуляции. На ранних этапах организм пытается поддержать кровоснабжение жизненно важных органов за счёт учащения сердцебиения и сужения периферических сосудов. Однако при продолжающейся потере объёма крови компенсаторных механизмов становится недостаточно, и перфузия тканей падает. Поэтому своевременное устранение причины и восстановление объёма циркулирующей жидкости имеют решающее значение для предупреждения необратимого повреждения органов.'),
  (E'7afbaf10-962e-4a31-9977-0a4fbac5503e', E'5e53c95d-b765-4035-9441-62b7e225557c', E'Шок — это остро развивающееся системное состояние, при котором кровообращение и микроциркуляция не обеспечивают органы достаточным количеством крови и кислорода. Возникают тканевая гипоксия, нарушения обмена веществ и повреждение органов; при тяжёлом течении развивается полиорганная недостаточность. Обычное эмоциональное переживание без физиологических нарушений не является шоком в патологоанатомическом смысле. Локальное расширение капилляров не описывает системного расстройства, а хроническая водянка одной полости имеет другой механизм. При кардиогенном шоке объём циркулирующей крови может быть сохранён, но сердце не способно обеспечить необходимый выброс. Поэтому лечение и патогенез отличаются от гиповолемического шока, при котором первично уменьшается наполнение сосудистого русла. Морфологические последствия кардиогенного шока связаны с гипоперфузией и гипоксическим повреждением органов, а также могут сочетаться с застоем крови при сердечной недостаточности.'),
  (E'5c97f5fb-45fb-4b87-b270-c3811db6360d', E'85dcaca1-326d-4ae2-b300-7a9f2a66b349', E'Гиповолемический шок развивается, когда быстро уменьшается объём циркулирующей крови или жидкости, например при массивной кровопотере или выраженном обезвоживании. Снижаются венозный возврат к сердцу и сердечный выброс, вследствие чего ухудшается кровоснабжение тканей. При кардиогенном шоке ведущая причина — недостаточная насосная функция сердца. Анафилактический шок связан с системной реакцией гиперчувствительности, а септический — с тяжёлой инфекцией и нарушением сосудистого тонуса и микроциркуляции. Важная особенность септического шока состоит в том, что нарушения кровообращения возникают не только из-за изменения давления, но и из-за патологической реакции эндотелия и распределения кровотока. Повышение сосудистой проницаемости способствует выходу жидкости в ткани, а нарушения микроциркуляции приводят к неоднородному снабжению органов кислородом. Поэтому даже при первоначально достаточном объёме крови клетки могут испытывать выраженную гипоксию.'),
  (E'89269d46-9285-4d40-8231-d4be241346fb', E'9836e11b-0bf4-49e7-be41-553aa19375f9', E'При кардиогенном шоке сердце не может перекачивать достаточный объём крови, поэтому сердечный выброс резко снижается. Органы получают меньше кислорода, развивается гипоперфузия и может возникнуть полиорганное повреждение. Потеря лимфы не является ведущим механизмом кардиогенного шока. Изолированное расширение кожных артериол при сохранном сердечном выбросе не объясняет системное нарушение кровоснабжения, а повышение онкотического давления плазмы не вызывает резкого падения насосной функции сердца. В почках при шоке изменения часто наиболее выражены в канальцах, чувствительных к недостатку кислорода. Если кровоснабжение восстанавливается своевременно, функция может постепенно улучшаться; при длительной ишемии повреждение становится тяжёлым и требует длительного восстановления. Острое повреждение почек усугубляет общее состояние, поскольку нарушаются выведение продуктов обмена и поддержание водно-электролитного равновесия.'),
  (E'78c03a9f-670a-4b31-8cde-2bcc41045a48', E'9877d26c-dccc-4828-8792-6b8af0df07aa', E'Флегмона — это разлитое гнойное воспаление, которое распространяется по рыхлой соединительной ткани и межтканевым пространствам. У неё нет сформированной ограниченной полости с капсулой, характерной для зрелого абсцесса, поэтому процесс может быстро захватывать большие участки и приводить к тяжёлой интоксикации. Фибринозный экссудат не является основой флегмоны, а поверхностное поражение эпителия не описывает глубокое диффузное гнойное воспаление.'),
  (E'741265a2-7c88-4506-8106-25bfcac5d33e', E'cad0bf41-8994-4a88-955a-a3d8d42acea1', E'Эмпиемой называют скопление гноя в уже существующей полости организма, например в плевральной или околоносовой пазухе. Абсцесс, в отличие от эмпиемы, образует новую патологическую полость внутри ткани. Флегмона характеризуется диффузным гнойным воспалением без чёткой границы. Образование фибриновой плёнки относится к фибринозному воспалению и не является определением эмпиемы.'),
  (E'1d25fced-af0f-428d-a084-bf47ed8b91c2', E'c606222f-5ffa-414d-945f-9371a3744a53', E'После оттока гноя и устранения возбудителя полость абсцесса очищается от некротических масс, заполняется грануляционной тканью и может зажить с образованием рубца. Чем больше объём разрушенной ткани, тем вероятнее фиброзное замещение вместо полного восстановления исходной структуры. Дифтеритическое воспаление представляет другую форму фибринозного процесса; генерализация инфекции возможна, но не обязательна; полное восстановление без рубца не гарантировано после тканевого расплавления.'),
  (E'013eee9b-17b8-4d73-98cd-1780499ae56c', E'b8b7a9ca-3971-446a-b225-5a4ea9ce68b6', E'Катаральное воспаление развивается только на слизистых оболочках и сопровождается образованием слизистого экссудата, который содержит слизь, слущенные эпителиальные клетки и различное количество лейкоцитов. Гной в замкнутой полости характерен для эмпиемы, плотные фибриновые массы с глубоким некрозом — для дифтеритического воспаления, а выраженная примесь эритроцитов — для геморрагического воспаления. Катаральная реакция может сочетаться с другими типами экссудата.'),
  (E'f2cbee0f-d3eb-4890-b2ab-36fe49c8140f', E'33fcbfd4-5e16-4e38-afd5-7261155f7203', E'При катаральном воспалении усиливается секреция слизи, а эпителий может набухать и слущиваться; в экссудате обнаруживаются слизь, эпителиальные клетки и лейкоциты. Гиалиновые мембраны относятся к определённым повреждениям альвеол, а не являются типичным признаком катара. Полнослойный некроз слизистой может сопровождать тяжёлые язвенно-некротические процессы, а плотная капсула вокруг гнойной полости характерна для созревающего абсцесса.'),
  (E'3eb828c7-d9c4-42c3-b86e-1547fbaccc05', E'7850d611-cb22-4add-9258-a8367cb82acb', E'Геморрагическое воспаление возникает при значительном повреждении сосудистой стенки и повышении её проницаемости, из-за чего эритроциты выходят в очаг и придают экссудату кровянистый вид. Оно может встречаться при тяжёлых инфекциях и токсических воздействиях и свидетельствует о выраженности повреждения. Слизистый экссудат определяет катаральную форму, прозрачная жидкость — серозную, а гнойный экссудат не исключает повреждения сосудов, но сам по себе не определяет геморрагический тип.'),
  (E'1ff307ce-fbe2-4426-80f2-371ae44e3ca2', E'eeccf857-b9ac-4532-9c79-518d9ad909a6', E'В остром воспалении медиаторы вызывают расширение сосудов и повышение проницаемости эндотелия. В результате жидкость и белки плазмы переходят в интерстициальную ткань или полости, формируя экссудат; одновременно в очаг мигрируют лейкоциты. Снижение проницаемости препятствовало бы выходу плазменных белков. Размножение фибробластов связано преимущественно с репарацией, а одно лишь уменьшение кровотока не объясняет формирование воспалительного экссудата.'),
  (E'5d8115ad-6144-4a56-8854-aa8d1e23fcdd', E'bef89f02-972c-4ea3-aa52-765fb5777c4f', E'При выраженном повреждении воспалительный процесс может приводить к некрозу и отторжению участка слизистой, формируя язву. Глубина дефекта зависит от того, насколько далеко распространяется некроз; при повреждении сосудов возможно кровотечение, а при глубоком дефекте — рубцевание. Полное восстановление без потери ткани соответствует благоприятному разрешению более поверхностного повреждения. Серозный выпот и амилоидоз не являются определением язвенно-некротического исхода.'),
  (E'825dd8f7-77c4-48fd-804b-2aa359f0bf0a', E'f48e2e81-98da-4748-b32a-6b43ba0366f4', E'Полное разрешение возможно, когда повреждение ограничено, причина устранена, а тканевые клетки способны к восстановлению. Экссудат и клеточный детрит удаляются макрофагами, жидкость резорбируется, а структура ткани возвращается близко к исходной. Замещение дефекта плотной соединительной тканью — это фиброзный исход, сохранение причины может поддерживать хронизацию, а распространение на соседние органы означает прогрессирование, а не разрешение процесса.'),
  (E'f93361b3-00db-41fc-b91a-d591bb23ec85', E'b4d3bcca-34f0-497b-86fc-9bee895dbda0', E'Хронизация вероятнее, если причина воспаления сохраняется, возбудитель плохо устраняется, продолжается воздействие токсина или присутствует длительное повреждение ткани. В таком очаге повторяются повреждение и репарация, меняется клеточный состав инфильтрата и может развиваться фиброз. Быстрое устранение причины и полноценное удаление экссудата, напротив, поддерживают разрешение. Кратковременная сосудистая реакция без существенного повреждения не является достаточным основанием для хронического процесса.'),
  (E'5ffe055d-64ea-485c-a103-c7edd230a219', E'c36b278a-2adc-437a-876d-0d778205d047', E'Организация развивается, когда экссудат, особенно богатый фибрином, не удаляется полностью и прорастает грануляционной тканью. Постепенно формируется соединительная ткань, что может приводить к спайкам в серозных полостях или к рубцеванию. Превращение экссудата в гной не является обязательным исходом. Удаление клеток и восстановление требуют активного участия макрофагов и репаративных механизмов, а полнота восстановления зависит от глубины и характера повреждения.'),
  (E'bc6b97d3-8040-4dbd-94e2-698280416a42', E'5f971284-9845-4ee9-9059-349d4d198715', E'Нейтрофилы быстро мигрируют из сосудов в очаг острого воспаления и играют центральную роль в уничтожении бактерий и удалении повреждённых тканей. При массовой гибели нейтрофилов и тканевом расплавлении формируется гной. Плазматические клетки чаще связаны с длительным гуморальным иммунным ответом, фибробласты участвуют в формировании грануляционной и рубцовой ткани, а эпителиоидные клетки характерны для гранулематозного воспаления, а не типичного острого гнойного очага.'),
  (E'9f0821d4-dd6a-4e7d-9493-4f3da6aac63e', E'af46c8a4-b63e-4896-8fab-1d445597f2dc', E'При фибринозном плеврите фибрин откладывается на поверхности листков плевры, из-за чего они становятся тусклыми и шероховатыми. Если наложения не рассасываются, они могут организоваться с разрастанием соединительной ткани и образованием плевральных спаек. Гной в плевральной полости означает эмпиему, слизистый экссудат в бронхах — катаральное воспаление, а ограниченная гнойная полость в ткани лёгкого — абсцесс.'),
  (E'4160d486-8c72-44d9-b0ac-31b325160c1b', E'e9230d97-a1c3-4a59-89f1-7df8a311d506', E'Экссудат формируется при воспалительном повышении проницаемости сосудов и обычно содержит больше белка и клеток, в том числе мигрировавшие лейкоциты. Транссудат возникает преимущественно из-за нарушений гидростатического или онкотического давления без выраженного воспалительного повреждения сосудистой стенки и обычно беден белком и клетками. Транссудат не характеризуется избытком нейтрофилов, а образование экссудата не требует разрыва крупной артерии.'),
  (E'1258eabd-4aad-4766-85b4-73c7947f1f46', E'aec64ef4-8d44-495d-8eaa-60fb173934a0', E'У детей характер воспалительной реакции меняется с возрастом: имеют значение зрелость врождённого и адаптивного иммунитета, особенности сосудистых реакций и строения тканей. Поэтому клиническая картина может быть менее типичной, а инфекция у маленьких детей иногда распространяется быстро. Нельзя утверждать, что воспаление всегда серозное или что нейтрофилы не участвуют в реакции. Исход также не гарантирован: возможны разрешение, нагноение, некроз, фиброз или генерализация.'),
  (E'6f7fc23f-827f-4160-9f4a-46f43f3e4318', E'3bc8db85-f9db-4ea5-8b71-ad478d26e409', E'В раннем возрасте иммунная защита и некоторые барьерные механизмы ещё созревают, а функциональные резервы органов меньше, чем у взрослых. Это может способствовать быстрому ухудшению состояния и распространению инфекции, хотя течение зависит от возбудителя, локализации и общего состояния ребёнка. Сосудистые реакции у детей присутствуют, экссудат может содержать белки, а фибринозные формы воспаления возможны; абсолютные утверждения об их отсутствии ошибочны.'),
  (E'd1e8c900-e317-4601-a6b0-552e75e5f069', E'736404fd-c1f3-43be-9d83-dcd8fcd0ceda', E'Фибринозный экссудат на брюшине при неполном рассасывании может прорастать грануляционной тканью и организовываться в соединительнотканные спайки. Они способны ограничивать подвижность органов, вызывать хронический дискомфорт или приводить к кишечной непроходимости. Эмпиема плевры относится к гнойному процессу в другой полости, катаральное воспаление бронхов не является исходом перитонита. Полное рассасывание возможно, но не гарантировано при обильном фибрине.'),
  (E'7b28ac3e-70b8-4f5e-83b8-74f16b7c8f01', E'e2b49a97-f721-463a-8f1e-a99506c0e303', E'Макрофаги фагоцитируют погибшие нейтрофилы, микроорганизмы и тканевой детрит, а также выделяют медиаторы, которые помогают переключить реакцию от активного повреждения к восстановлению. Они могут стимулировать ангиогенез и работу фибробластов при репарации. Фибрин образуется из фибриногена под действием системы свёртывания, а сосудистое расширение регулируется множеством медиаторов. Макрофаги не всегда поддерживают хронизацию: их функция зависит от сигналов и стадии процесса.'),
  (E'd14771f9-7927-4fc6-89ae-6a8ed6d09cf9', E'33ee4ab2-eb37-450d-ae68-34ca0832f7a0', E'При поверхностном катаральном воспалении после устранения раздражителя слизь и слущенные клетки удаляются, секреция постепенно нормализуется, а эпителий восстанавливается. Глубокий рубец возникает при значительной утрате ткани, чего при неосложнённом поверхностном процессе обычно нет. Абсцесс требует гнойного расплавления ткани, а спайки формируются при организации экссудата на серозных оболочках, а не являются типичным исходом катарального воспаления слизистой.'),
  (E'6ed6c634-83a1-4f01-8b79-1bad5440dc72', E'bef0ca55-23ac-423c-a693-bca33acf768a', E'Обширный некроз и большое количество клеточного детрита свидетельствуют о выраженном повреждении ткани и повышают вероятность язвообразования, нагноения, фиброзного замещения или нарушения функции органа. Кратковременное расширение сосудов может быть обратимой частью воспалительной реакции. Небольшой серозный экссудат при сохранной структуре чаще разрешается благоприятно, а усиление секреции слизи без существенного повреждения соответствует более поверхностной катаральной реакции.'),
  (E'88abbdfc-722d-41dc-a1ad-251e2befdec8', E'3bdcd4c5-2b1c-4027-8d73-04a74ed0b636', E'Полное восстановление возможно, если повреждение ограничено, тканевой каркас сохранён и клетки способны к регенерации. При глубокой утрате ткани, разрушении опорных структур или низкой регенераторной способности дефект заполняется грануляционной тканью и созревающим рубцом. Цвет экссудата может подсказать его состав, но не определяет самостоятельно исход. Лихорадка и объём жидкости в сосудистом русле отражают отдельные аспекты реакции и не являются решающими критериями восстановления или фиброза.'),
  (E'19f9b670-955f-4ee1-bfeb-d652d59d202e', E'4e465b6e-f4e4-4e70-8d91-e6dc27a23a1c', E'Морфологическая форма экссудативного воспаления определяется преобладающим компонентом: при серозном образуется жидкий экссудат, при фибринозном выпадает фибрин, а при гнойном преобладают нейтрофилы и тканевой детрит. Катаральное воспаление связано со слизью на слизистых оболочках, геморрагическое — с выраженной примесью эритроцитов. Гной в существующей полости определяет эмпиему, а фибробласты и некротические плёнки не являются определяющими компонентами серозного или гнойного экссудата.'),
  (E'e25cba46-6d7b-43a7-af0f-3f36ab917dff', E'9919de7e-19c4-4935-a168-e983536d04ea', E'При пролиферативном воспалении ведущим становится размножение клеток — макрофагов, лимфоцитов, плазматических клеток, фибробластов и других элементов, в зависимости от причины и локализации процесса. Это отличает его от экссудативного воспаления, где преобладает выход жидкости и белков плазмы. Гнойная полость характерна для абсцесса, а поверхностные отложения фибрина — для фибринозного воспаления; ни то ни другое не является обязательным признаком продуктивного процесса.'),
  (E'c61c1f78-51a7-4c01-aae5-1ca0228c7f65', E'b5d2be42-2f2b-4319-a46f-6e7127bfff99', E'Классически выделяют межуточное (интерстициальное) воспаление, гранулематозное воспаление и продуктивное воспаление с образованием полипов или остроконечных кондилом. Это деление основано на характере тканевой реакции и морфологическом результате. Серозное, фибринозное, гнойное и геморрагическое — варианты экссудативного воспаления. Крупозное и дифтеритическое описывают формы фибринозного воспаления, а артериальное и венозное обозначают типы сосудистых нарушений, а не классификацию воспаления.'),
  (E'16c310d9-26b4-4f84-a9a8-3b036f6d2272', E'b40bdb8e-c25d-414c-a50d-a5940f2e5a31', E'Картина соответствует интерстициальному миокардиту с клеточным инфильтратом в строме и повреждением паренхиматозных клеток. Кардиомиоциты обладают ограниченной способностью к полноценной регенерации, поэтому участки повреждения замещаются соединительной тканью, что ведет к диффузному мелкоочаговому кардиосклерозу. Массовое восстановление миокарда делением кардиомиоцитов нехарактерно. Казеозные гранулемы заставили бы думать о специфическом гранулематозном процессе, а эмпиема означает скопление гноя в естественной полости, чего в условии нет.'),
  (E'9a6a8fa5-1bbf-457b-99a8-09f20054f792', E'dcf3d2b5-506b-4167-bee0-1dc0108acf52', E'Гранулематозная реакция развивается, когда раздражитель сохраняется в тканях и плохо устраняется мононуклеарными фагоцитами. Макрофаги накапливаются, активируются и могут приобретать эпителиоидный вид; иногда формируются многоядерные гигантские клетки, а по периферии располагаются лимфоциты и фибробласты. Кратковременный стимул обычно не поддерживает стойкое образование гранулемы. Повышенная сосудистая проницаемость может сопровождать воспаление, но сама по себе не формирует гранулему; фибринозная пленка также не является обязательной стадией.'),
  (E'4b9d6f7d-0399-4514-9fbd-98f1a042f6a2', E'a1db9a14-a06d-4c1a-9203-efc5aa12d8f3', E'Сочетание небольшого центрального казеозного некроза, эпителиоидных клеток, гигантских клеток Пирогова—Лангханса и периферического лимфоцитарного вала типично для туберкулезной гранулемы. Однако сходные гранулематозные реакции встречаются и при других заболеваниях, поэтому морфологию сопоставляют с клиническими данными и выявлением возбудителя. Для саркоидоза более характерны эпителиоидно-клеточные гранулемы без выраженного казеозного некроза. При лепроматозной форме важны клетки Вирхова с микобактериями, а полип слизистой имеет совершенно другую тканевую организацию.'),
  (E'a65e0736-1c1a-45ac-afb9-ce920b2ae6d0', E'b12099d0-4cda-4d6c-8799-a61fe4a70141', E'Основу гранулемы составляют клетки моноцитарно-макрофагального ряда. Макрофаги могут трансформироваться в эпителиоидные клетки, а при слиянии образуют многоядерные гигантские клетки. Вокруг них нередко располагаются лимфоциты, а при длительном течении — фибробласты и коллагеновые волокна. Нейтрофильный гнойный экссудат характерен прежде всего для гнойного воспаления, эритроцитарное пропитывание — для геморрагических изменений, а одни зрелые фибробласты с коллагеном скорее указывают на сформировавшийся рубец, а не на активную гранулему.'),
  (E'2666195e-8025-44ad-9f5d-ec042bd6e6da', E'37a3aed7-648f-4004-ae4d-8311a391d8b4', E'При интерстициальном воспалении воспалительный инфильтрат располагается преимущественно в межуточной ткани — строме миокарда, печени, почек или легких. При этом функциональные клетки органа могут вторично подвергаться дистрофии и некробиотическим изменениям из-за воспалительной реакции и нарушений микроциркуляции. Процесс не ограничивается эпителием слизистых оболочек, а казеозный некроз не является обязательным признаком. Утверждение об отсутствии повреждения паренхимы тоже неверно: такое повреждение нередко определяет функциональные последствия заболевания.'),
  (E'099a5601-3d2f-45e2-bfbc-c2049ab4b1bd', E'8c598bdf-7d78-4fdb-94db-cfa6c6f9b987', E'Длительное воспаление поддерживает активацию макрофагов и других клеток, выделяющих медиаторы, стимулирующие фибробласты. Фибробласты синтезируют коллаген и другие компоненты внеклеточного матрикса, поэтому при устойчивом повреждении нарастает фиброз и может нарушаться нормальная архитектоника органа. Простое исчезновение клеток не объясняет накопление соединительной ткани. Нейтрофильное расплавление соответствует гнойному воспалению, а превращение макрофагов в гепатоциты не является механизмом регенерации печени.'),
  (E'cbebfd8a-b4f9-4dfd-a47d-f2e268e0190d', E'94b7b401-1c60-4a1e-a912-709b9fe89c43', E'Сифилитическая гумма — очаговое гранулематозное образование третичного периода сифилиса. В центре располагается крупный участок некроза, по периферии — гранулематозная ткань с лимфоцитами, плазматическими клетками, эпителиоидными клетками и фибробластами; характерны многочисленные мелкие сосуды с продуктивным эндоваскулитом и формирование соединительнотканной капсулы. Клетки Вирхова связаны с лепроматозной лепрой. Неказеозные компактные гранулемы типичнее для саркоидоза, а нейтрофильный экссудат в естественной полости соответствует эмпиеме.'),
  (E'05dffe5d-e133-4a28-af1a-573bd894720f', E'0a2cc6fd-f88c-4874-9b96-a3291fb3be84', E'При лепроматозной форме лепры гранулемы содержат многочисленные макрофаги, в том числе вакуолизированные клетки Вирхова, в цитоплазме которых обнаруживаются микобактерии лепры. Возбудители могут располагаться скоплениями, напоминающими сигары в пачке. Туберкулоидная форма характеризуется более выраженной клеточной реакцией и эпителиоидно-клеточными гранулемами, а микобактерии выявляются редко. Саркоидоз не характеризуется клетками Вирхова, а гумма при сифилисе имеет иной клеточный состав и выраженный сосудистый компонент.'),
  (E'9bf79719-2d94-49ef-bc48-fb44beb7440c', E'26552ec7-12cf-4f93-8394-a3bbcdea253e', E'Для саркоидоза характерны эпителиоидно-клеточные гранулемы, обычно без выраженного казеозного некроза. Этот признак помогает отличать их от типичных туберкулезных гранулем, хотя по одной морфологии не всегда возможно окончательно установить этиологию. Казеозный некроз и выявление микобактерий поддерживают диагноз туберкулеза; клетки Вирхова характерны для лепроматозной лепры. Гумма с плазматическими клетками и продуктивным эндоваскулитом типична для третичного сифилиса, а нейтрофильный экссудат с полостью — для абсцесса.'),
  (E'eadc289f-e846-4a79-8ebe-e197eefd7b29', E'35a6418d-602e-498c-80e5-5ee11d045b3c', E'Многоядерные гигантские клетки формируются преимущественно путем слияния активированных макрофагов в условиях длительного воспалительного раздражения. Их наличие отражает попытку клеточной системы фагоцитоза справиться с агентом, который трудно устранить обычным путем. Коллагеновые волокна не содержат ядер и не могут делиться на них. Эритроциты у человека безъядерны, поэтому не дают многоядерных клеток. Нейтрофилы не превращаются в фибробласты: это разные клеточные линии с различными функциями.'),
  (E'0fd22f99-1b3f-45fd-b8ff-bc05d2622188', E'99486a23-b3ce-4edd-bdcc-d5944fb1f860', E'В исходе туберкулезной гранулемы обычно происходит организация очага с формированием небольшого соединительнотканного рубчика; в некоторых случаях развивается петрификация, то есть отложение солей кальция. Исход зависит от размера очага, активности инфекции и иммунного ответа. Гнойная полость не является обязательным результатом гранулемы, а полное восстановление исходной архитектуры ткани не гарантировано. Клетки Вирхова связаны с лепрой и не являются исходом туберкулезной гранулемы.'),
  (E'f045e6fa-9792-40f5-abdf-26bb4405cbb9', E'd3d285bf-8903-4e88-8651-ec85d9b34a23', E'Гуммозный инфильтрат при сифилитическом мезаортите отличается от типичной гуммы диффузным расположением и отсутствием характерного центрального казеозного некроза. Инфильтрат развивается преимущественно в средней оболочке аорты, распространяясь по vasa vasorum; продуктивный васкулит нарушает питание стенки и разрушает эластический каркас. Замещение поврежденных структур соединительной тканью ослабляет стенку и способствует формированию аневризмы. Нейтрофильная эмпиема и клетки Вирхова относятся к другим патологическим процессам.'),
  (E'7b60a693-69f5-461f-be5e-b615fe33d561', E'74d6074d-33e9-438d-a8d1-6905be052bef', E'При сифилитическом мезаортите продуктивный воспалительный процесс поражает vasa vasorum, нарушая трофику средней оболочки аорты. Одновременно воспалительный инфильтрат и тканевое повреждение разрушают эластические волокна; на их месте разрастается соединительная ткань. Стенка теряет эластичность и прочность, постепенно истончается и может выбухать в виде мешковидной аневризмы. Фибрин на интиме не объясняет разрушение средней оболочки, а кальцификация клапанов является другим процессом и не представляет обязательного механизма сифилитической аневризмы.'),
  (E'228ce249-6204-4198-83f9-ba0129fb7ce1', E'e85f2d0e-5da3-471b-aea0-d90704793367', E'Гранулемы могут возникать при инфекциях, когда возбудитель длительно сохраняется в ткани, а также при воздействии неинфекционных трудноустранимых материалов, например инородных частиц. В обоих случаях важна реакция макрофагов, но клеточная организация и диагностические признаки зависят от конкретной причины. Инфекционные гранулемы не лишены макрофагов — напротив, они являются их основой. Казеозный некроз не обязателен ни для всех инфекционных, ни для неинфекционных гранулем. Поэтому этиология важна для интерпретации морфологии и выбора дальнейших исследований.'),
  (E'91c3c3bd-0145-4bd4-8003-845117226c23', E'4050f5d6-d6f5-44b8-9e06-51b484608ed4', E'Гранулема инородного тела возникает вокруг материала, который не может быть эффективно удален или расщеплен фагоцитами. Вокруг частиц скапливаются макрофаги и могут формироваться многоядерные гигантские клетки; выраженность лимфоцитарного компонента зависит от природы материала и условий реакции. Казеозный некроз и клетки Пирогова—Лангханса характерны для ряда инфекционных гранулем, но не обязательны при инородном теле. Продуктивный эндоваскулит с плазматическими клетками типичнее для сифилитического поражения, а микобактерии не являются универсальным компонентом.'),
  (E'c8eb457e-1335-45c3-9f61-3700a5d7d428', E'7d8b0388-ccf5-4f04-aa2e-1c19203c7b55', E'Гранулематозными называют заболевания, при которых характерной тканевой реакцией становится образование гранулем. Они могут иметь инфекционную, иммунную или иную природу, поэтому термин описывает прежде всего морфологический тип реакции, а не единую этиологию. Отек и гиперемия встречаются при множестве воспалительных процессов, но не означают образования гранулем. Гнойные инфекции также не исчерпывают группу гранулематозных заболеваний, а гранулема является воспалительной структурой, а не опухолью моноцитарного ряда.'),
  (E'138785f1-be5d-4279-b935-600feffc8e1c', E'c8cea4da-4e1d-474d-84e5-d66a93ac69d9', E'Морфологическое отсутствие видимого возбудителя не всегда означает неинфекционную природу гранулемы: микроорганизмов может быть мало, они могут плохо окрашиваться или находиться вне исследованного среза. Диагноз устанавливают с учетом локализации, клинической картины, специальных окрашиваний, микробиологических и молекулярных методов. Саркоидоз нельзя устанавливать только по одному признаку, поскольку похожие гранулемы встречаются при других заболеваниях. Гранулематозная реакция часто включает иммунные механизмы, поэтому утверждение об их отсутствии также необоснованно.'),
  (E'8ff709ac-489b-4d05-8649-a73820088931', E'41247bba-10b0-404a-8615-880df7f55288', E'Склеромная гранулема состоит из лимфоцитов, плазматических клеток и характерных клеток Микулича, в которых могут обнаруживаться возбудители склеромы; также описываются гиалиновые шары, связанные с измененными плазматическими клетками. Гранулемы обычно располагаются в слизистой оболочке верхних дыхательных путей и быстро подвергаются склерозу и гиалинозу, что может приводить к стенозу и даже асфиксии. Клетки Вирхова типичны для лепры, казеозные гранулемы — для туберкулеза, а неказеозные гранулемы характерны для ряда других состояний.'),
  (E'1b29b77c-a2eb-4b6a-85ed-25a9d8b91b00', E'd730ede9-650d-4b8f-8b73-81ae717b9a1a', E'Лепра демонстрирует различия тканевой реакции в зависимости от формы заболевания. При лепроматозной форме макрофаги многочисленны и содержат большое количество микобактерий, образуя характерные клетки Вирхова. При туберкулоидной форме клеточный иммунный ответ выражен сильнее, формируются эпителиоидно-клеточные гранулемы, напоминающие туберкулезные, но микобактерии обнаруживаются редко. Казеозный некроз не является обязательным признаком лепры, а клетки Микулича и гиалиновые шары связаны со склеромой.'),
  (E'8c20b8b8-8cbd-4eff-bef2-b202bbf80ade', E'38561c6f-70f1-4872-bd0a-633fc9f75ba3', E'При гранулематозном воспалении клеточный иммунный ответ, включая активацию макрофагов лимфоцитами, способствует формированию и поддержанию гранулемы. Активированные макрофаги приобретают эпителиоидный вид, а иногда сливаются в гигантские клетки. Однако стойкий агент может сохраняться даже при выраженной реакции, поэтому воспаление становится хроническим и может завершаться фиброзом или некрозом. Иммунная активация не устраняет гранулемы автоматически, не сводится к выходу плазмы и не обязательно приводит к гнойному расплавлению.'),
  (E'3b91eca2-7afe-455a-b986-8321b024b840', E'afb07406-bf26-4882-a376-a184eb91bcda', E'При длительном интерстициальном воспалении сохраняющееся повреждение и активация фибробластов приводят к накоплению коллагена и склерозу. По мере разрастания соединительной ткани может нарушаться архитектоника органа, развиваться атрофия паренхимы и снижение функции. Полное восстановление возможно не во всех тканях и не при длительном значительном повреждении. Инфильтрирующие клетки не превращаются поголовно в эпителий, а образование эмболов относится к сосудистым осложнениям и не является типичным исходом интерстициального воспаления.'),
  (E'65ff643f-a213-4eb0-9fa8-a8ba8497d773', E'a55ba53f-082b-4aa3-84aa-c4e5becd2bbe', E'Хроническое воспаление часто сочетает персистирующий инфильтрат, повреждение ткани и репаративную реакцию. Макрофаги и другие воспалительные клетки выделяют медиаторы, которые поддерживают повреждение, но одновременно активируют фибробласты и синтез внеклеточного матрикса. Поэтому в одном очаге могут сосуществовать активное воспаление и фиброз. Наличие рубцевания не доказывает полного завершения процесса: причина может сохраняться. Такая картина не характерна исключительно для острого серозного воспаления и не исключает участия макрофагов.'),
  (E'7392f23e-6e96-48b8-b3e7-3cb7e8e67109', E'f1edba1e-9063-4707-8e7c-05915a2dad22', E'Воспалительные гиперпластические полипы формируются при длительном раздражении и воспалении слизистой оболочки, когда усиливаются клеточная пролиферация и регенераторные процессы. Разрастание ткани выступает над поверхностью и может иметь ножку или широкое основание; состав зависит от органа и характера хронического воспаления. Кровоизлияние само по себе не объясняет полиповидную гиперплазию, амилоидоз относится к отложению патологического белка, а казеозные гранулемы не являются обязательной основой воспалительного полипа.'),
  (E'd1d8cc58-58b8-4d4b-bd95-a1298bd1dc5c', E'f0e49408-a057-48ae-9ad4-7604a0c59031', E'Остроконечные кондиломы представляют собой экзофитные папиллярные разрастания эпителия и соединительнотканной основы, возникающие в аногенитальной области и часто связанные с вирусом папилломы человека. В классическом описании продуктивных воспалительных процессов их рассматривают среди разрастаний слизистых оболочек и покровного эпителия. Абсцесс отличается гнойной полостью, фибринозное воспаление — поверхностными отложениями фибрина, а казеозная гранулема с микобактериями характерна для туберкулеза и морфологически не соответствует кондиломе.'),
  (E'870e41a6-72e6-46aa-824f-56a2f28844df', E'87790f67-1a33-4600-9df5-c2c4ab0dabc4', E'Хроническое воспаление поддерживается, когда причина повреждения сохраняется, плохо устраняется либо продолжается иммунная реакция против собственных или внешних антигенов. В очаге одновременно могут присутствовать макрофаги, лимфоциты, плазматические клетки, повреждение ткани, ангиогенез и фиброз. Кратковременная сосудистая реакция без клеточного компонента чаще относится к ранним изменениям острого воспаления и не объясняет хронизацию. Если причина полностью устранена, воспаление может разрешиться, хотя степень восстановления зависит от глубины повреждения и способности ткани к регенерации.'),
  (E'b55eef05-278f-47bb-9818-d2e43154650c', E'9474f41f-4f0b-4317-a78b-2fdc5de03b46', E'Полиповидное выступание слизистой в сочетании с хроническим клеточным инфильтратом, сосудистыми изменениями и фиброзом соответствует продуктивному воспалению с гиперпластическим полипообразованием. Такая реакция возникает при длительном раздражении и повторном повреждении слизистой. Дифтеритическая пленка представляет собой фибринозный экссудат с некрозом поверхности, а абсцесс требует локальной гнойной полости. Жировая дистрофия — внутриклеточное накопление липидов и не объясняет тканевую гиперплазию и полиповидную архитектуру.'),
  (E'9e221404-79da-4301-aff8-a9c1a4fe5a4a', E'a40060b7-7c19-46b8-87a4-78d86a8f3738', E'Гранулема — организованное узелковое скопление клеток моноцитарно-макрофагального ряда, часто с эпителиоидными и гигантскими клетками, а также лимфоцитами по периферии. В отличие от нее, обычный хронический инфильтрат может быть диффузным и не иметь четкой узелковой организации. Наличие лимфоцитов само по себе недостаточно для определения гранулемы. Выраженный отек без клеточной реакции больше соответствует сосудистому компоненту воспаления, а разлитое скопление нейтрофилов характернее для гнойного процесса.'),
  (E'aea35f40-df09-464f-87b3-53054d544739', E'9118d3d3-13a6-4d8f-a526-ad51295ba36c', E'Гранулематозное воспаление представляет собой определенный тип тканевой реакции, который может развиваться при различных инфекционных и неинфекционных воздействиях. Некоторые признаки помогают сузить дифференциальный ряд, например казеозный некроз при типичной туберкулезной гранулеме, но не всякая гранулема имеет уникальный набор признаков. Отсутствие некроза не исключает инфекционную природу, а гигантские клетки встречаются в гранулемах разного происхождения. Поэтому для окончательного заключения морфологические данные сопоставляют с клиникой и результатами специальных исследований.'),
  (E'741d8e96-df45-481b-b9d3-325f94b2bc42', E'5ab450c9-f262-4b01-b29e-53fddbea6c73', E'При прогрессирующем склерозе соединительная ткань замещает поврежденные функциональные структуры и изменяет нормальную архитектонику органа. В тканях с ограниченной способностью к регенерации, например миокарде, это может приводить к атрофии оставшихся элементов и стойкому снижению функции. Неограниченное восстановление специализированных клеток не является универсальным ответом на повреждение. Склероз не обязан переходить в гнойное воспаление, а его морфологическая основа, напротив, связана с накоплением внеклеточного матрикса, а не его исчезновением.'),
  (E'bed3b3d8-428d-4ac2-914b-fa8c37cf3f39', E'c9767241-4990-4990-b90e-58096ded6e13', E'Исход гранулематозного воспаления зависит от природы агента, его устойчивости, иммунного ответа и локализации. Очаги могут сохраняться длительно, подвергаться некрозу, организации и фиброзу; при множественных очагах рубцевание способно деформировать орган и нарушать его функцию. Полное разрешение возможно в некоторых ситуациях, но не является обязательным при устойчивом раздражителе. Эмпиема требует накопления гноя в естественной полости, а гранулема не является предшественником злокачественной опухоли по определению.'),
  (E'b64549c8-77a0-42fe-bb0a-302d34910c04', E'1a7604fd-4f68-4d4d-822f-521e540384a8', E'Хроническое воспаление характеризуется сочетанием инфильтрации мононуклеарными клетками, продолжающегося повреждения ткани и процессов восстановления, включая ангиогенез и фиброз. Эти компоненты могут сосуществовать и поддерживать друг друга. При остром воспалении часто доминируют сосудистые реакции и нейтрофилы, хотя исключения возможны в зависимости от причины. Хронический процесс не лишен сосудистых изменений, а кратковременная вазодилатация без клеточного инфильтрата сама по себе не отражает полноценную морфологию хронического воспаления.'),
  (E'e0e2df27-1006-4fbf-9612-7eed44406cc9', E'22c2b821-fb99-4561-b79f-7f8290a331e8', E'Лимфоциты и плазматические клетки отражают участие адаптивного иммунного ответа, а макрофаги выполняют фагоцитарные и регуляторные функции и могут поддерживать репарацию или повреждение ткани. Такой клеточный состав часто встречается при хроническом воспалении, но не является специфичным для одной болезни. При сифилисе он может сочетаться с характерными сосудистыми изменениями и другими признаками, однако по одному составу инфильтрата диагноз не устанавливают. Наличие этих клеток не исключает повреждения ткани и фиброза.'),
  (E'ab162df1-ee44-4b42-8aea-6e6d44910483', E'4944b36f-836b-4bb0-86cf-45aa5cf2783c', E'Термин «специфическая гранулема» применяют к гранулематозным образованиям, имеющим характерные морфологические особенности при определенных заболеваниях, например туберкулезе, сифилисе или лепре. Эти особенности могут существенно помочь диагностике, но должны оцениваться в контексте клинических данных и лабораторного подтверждения. Не все гранулемы содержат один и тот же возбудитель или имеют одинаковое строение. Гнойный очаг из нейтрофилов не является гранулемой в строгом смысле, а полип слизистой имеет иную архитектуру.'),
  (E'0bc4f8d3-2b3d-461b-a7e1-56ae29b80178', E'caffd124-8026-4af3-890e-8d45ee8fb1b4', E'При анафилаксии аллерген связывает соседние молекулы IgE, фиксированные на Fcε-рецепторах тучных клеток и базофилов. Дегрануляция высвобождает гистамин и другие медиаторы, вызывающие вазодилатацию, повышение сосудистой проницаемости, бронхоспазм и падение артериального давления. Иммунные комплексы и комплемент типичнее для гиперчувствительности III типа. CD8+ лимфоциты участвуют в клеточно-опосредованном повреждении, а гранулёмы формируются при длительной активации макрофагов, а не при немедленной анафилаксии.'),
  (E'c260ff7d-b91c-4845-81cd-49ff0a7fb6fd', E'14d3a40f-4628-45bd-b149-b39c9be9c57b', E'Мукоидное набухание обратимо: после устранения причины структура ткани может восстановиться. При сохранении повреждающего воздействия дезорганизация соединительной ткани может углубляться и переходить в фибриноидное набухание. Амилоидное сморщивание связано с выраженным амилоидозом, а не с обратимым мукоидным набуханием; рубец не формируется обязательно; жировая эмболия — сосудистое осложнение попадания жировых капель в кровоток и не является исходом этого процесса. Обратимость объясняется тем, что при мукоидном набухании обычно ещё не произошло грубого разрушения коллагеновых и эластических волокон. Если этиологический фактор сохраняется, процесс может прогрессировать до более глубокого повреждения соединительной ткани. Следовательно, полное восстановление возможно, но не является неизбежным при продолжающемся воздействии причины.'),
  (E'a01737a6-4d53-476c-ba23-a93aaae84858', E'5badd08f-8cb5-4a99-91a5-d9f5f0ae63be', E'При гиперчувствительности II типа антитела IgG или IgM распознают антигены на поверхности клеток либо в составе внеклеточных структур. Повреждение возникает через комплемент, Fc-рецептор-зависимый фагоцитоз, антителозависимую цитотоксичность или изменение функции рецепторов. Растворимые комплексы с тканевым отложением характерны для III типа. IgE и тучные клетки определяют I тип. T-клеточные реакции с цитокинами относятся к IV типу и обычно развиваются медленнее.'),
  (E'52be8585-241b-4165-8ea8-3e16335a0c10', E'498557df-38ae-4b31-8673-cda4d4854137', E'III тип обусловлен образованием иммунных комплексов, которые задерживаются в тканях, активируют комплемент и привлекают нейтрофилы. Их ферменты и активные формы кислорода повреждают сосуды и базальные мембраны; возможны васкулит и гломерулонефрит. I тип связан с IgE и тучными клетками. При II типе антитела направлены против фиксированных клеточных или тканевых антигенов, а IV тип реализуется T-лимфоцитами без ведущей роли антител.'),
  (E'1ce8fc2a-7745-4c4b-974a-fb9e81fb5893', E'5f8a84bc-2d8d-4584-8d30-58f065e1f069', E'При ГЗТ сенсибилизированные T-лимфоциты распознают антиген и выделяют цитокины, прежде всего активирующие макрофаги и усиливающие локальное воспаление. Реакция развивается в течение 24–72 часов, а уплотнение связано с клеточной инфильтрацией и отёком. IgE-зависимый механизм объясняет немедленную аллергию. Иммунные комплексы характерны для III типа. Нейтрализация токсина антителами сама по себе не создаёт типичную клеточную реакцию замедленного типа.'),
  (E'69a7a24b-070a-416b-abfe-952e36e33f71', E'a4a1f967-001a-4fc1-b3a0-b7baa8ccc2b6', E'Контактный дерматит — классический пример IV типа гиперчувствительности: небольшие химические вещества становятся антигенными после связывания с белками, а сенсибилизированные T-клетки при повторном контакте запускают воспаление. Лимфоцитарная инфильтрация и спонгиоз эпидермиса соответствуют этой реакции. I тип обычно развивается быстро и связан с IgE. II тип предполагает антитела против фиксированных антигенов. III тип обусловлен иммунными комплексами и чаще сопровождается васкулитом или депозитами в тканях.'),
  (E'3fdc5a7c-e9c0-4c56-b299-de0461865d06', E'b351572d-941b-447b-b9e5-47f85ec1bc65', E'При болезни Грейвса аутоантитела связываются с рецептором тиреотропного гормона и стимулируют его, вызывая гиперплазию фолликулярного эпителия и гипертиреоз. Это функциональный вариант гиперчувствительности II типа: антитела меняют работу рецептора, а не обязательно уничтожают клетку. Иммунные комплексы не являются основным механизмом. При тиреоидите Хашимото, напротив, значительную роль играет лимфоцитарное повреждение и постепенная утрата тиреоцитов. Амилоид не объясняет стимуляцию рецептора.'),
  (E'dfd0c48c-f29b-468a-91ca-87bc9c3ab8e7', E'c644dd5c-8683-42c7-8866-3d34b9325a6c', E'Хашимото возникает при нарушении толерантности к тиреоидным антигенам, включая тиреопероксидазу и тиреоглобулин. Аутоантитела служат диагностическими маркерами и могут участвовать в повреждении, однако важную роль играет T-клеточное воспаление с гибелью тиреоцитов. Изолированная блокада рецептора ТТГ не описывает типичный механизм Хашимото. Иммунные комплексы в клубочках относятся к другому типу патологии, а IgE-зависимая дегрануляция характерна для аллергии немедленного типа.'),
  (E'389dc2c8-4d2e-4ca9-896c-3d5f7bc12d13', E'172295f6-b0d5-4e3f-b24e-0a674ea7ebce', E'СКВ — системное аутоиммунное заболевание с широким спектром аутоантител, в том числе к двуспиральной ДНК и другим ядерным антигенам. Иммунные комплексы могут откладываться в клубочках, коже, сосудах и серозных оболочках, активируя комплемент. Антитела к рецептору ТТГ характерны для болезни Грейвса. Линейное свечение IgG вдоль базальной мембраны типично для синдрома Гудпасчера. Изолированная нейтропения не отражает основного механизма СКВ.'),
  (E'33571c6e-ea78-420a-9ecc-92cee3c4a304', E'34e15802-63cd-42cf-a512-9eb2c4223fb6', E'При синдроме Гудпасчера аутоантитела направлены против компонентов базальных мембран, прежде всего α3-цепи коллагена IV типа. В почках это вызывает некротизирующий гломерулонефрит с полулуниями, а в лёгких — кровоизлияния в альвеолы. Иммунофлюоресценция показывает линейное свечение IgG вдоль базальных мембран. Гранулярные депозиты характернее для иммунокомплексных процессов, клетки Гюртле — для Хашимото, а казеозные гранулёмы — для туберкулёза.'),
  (E'2e1ca21e-e9b0-48f0-b03a-3ee7aaecc096', E'fe75a638-8c2d-4370-bbaa-6a2de62ced54', E'Первичные иммунодефициты связаны с генетическими дефектами развития или функции компонентов иммунной системы — B-клеток, T-клеток, фагоцитов, комплемента или комбинированных звеньев. Они нередко проявляются в детстве, но отдельные формы диагностируют и у взрослых. Химиотерапия и ВИЧ могут приводить к вторичному иммунодефициту. Реакция против собственных антигенов относится к аутоиммунитету, а повышенный IgE при атопии — к определённым аллергическим состояниям.'),
  (E'e495d31e-098e-46d8-b53b-011825fa00fc', E'5feda9d8-ef1d-47d8-a836-4bec57852451', E'Снижение всех классов иммуноглобулинов при сохранном количестве T-клеток указывает на дефект гуморального иммунитета, связанный с развитием или функцией B-клеток и плазматических клеток. Такие пациенты особенно восприимчивы к инфекциям, вызываемым инкапсулированными бактериями. Дефект цитотоксических T-клеток чаще приводит к нарушениям клеточного противовирусного ответа. Нейтрофильные дефекты сопровождаются нарушением фагоцитоза, а дефицит отдельного компонента комплемента обычно не снижает сразу все классы иммуноглобулинов.'),
  (E'59fe811f-1572-4f0c-ad3a-7f19f10924ba', E'b0eba970-5bb4-4d16-905b-20f327817103', E'При тяжёлом комбинированном иммунодефиците нарушены T-клеточное звено и, прямо или косвенно, функции B-клеток. Поэтому возникают тяжёлые, повторные бактериальные, вирусные, грибковые и оппортунистические инфекции; без своевременного лечения они могут приводить к задержке развития и смерти. Изолированный аутоиммунный тиреоидит не объясняет тяжесть синдрома. AL-амилоидоз не является типичным непосредственным осложнением. Аллергические реакции не отражают основной риск при комбинированном иммунодефиците.'),
  (E'8102efc9-83c3-4619-814c-f25010a978c9', E'7a157192-7577-4632-b3e1-65b78141bfde', E'CD4+ T-хелперы координируют иммунный ответ, активируют макрофаги и помогают B-клеткам формировать эффективные антительные реакции. Их потеря ведёт к прогрессирующему иммунодефициту и повышенной восприимчивости к оппортунистическим инфекциям и некоторым опухолям. Увеличение антителозависимой цитотоксичности не является прямым следствием. Иммунокомплексный васкулит не объясняет основной спектр осложнений ВИЧ. Нейтропения возможна по разным причинам, но не означает полной утраты продукции нейтрофилов.'),
  (E'fb61f786-1017-456c-96ec-8c4c4896cfe9', E'867c505a-a398-44dc-a11b-d5f197c26844', E'При тяжёлом комбинированном иммунодефиците главная непосредственная угроза — тяжёлые и повторные инфекции, в том числе оппортунистические, которые могут привести к дыхательной недостаточности, сепсису и полиорганной дисфункции. Гипертиреоз связан с аутоантителами к рецептору ТТГ и не является ожидаемым исходом иммунодефицита. СКВ не развивается обязательно. Разрыв амилоидно изменённой селезёнки не относится к типичным причинам смерти при данном состоянии.'),
  (E'858ba74a-f43d-4a43-a901-423ddcabc886', E'ede5b4e1-0fd6-4f1f-b6d0-fcb837c3bbca', E'Амилоидоз — группа состояний, при которых во внеклеточном пространстве накапливаются фибриллы неправильно свернутых белков, образующие характерные нерастворимые депозиты. При окраске конго красным они дают яблочно-зелёное двулучепреломление в поляризованном свете. Накопление триглицеридов — жировая дистрофия. Иммунные комплексы могут откладываться в тканях, но это иной процесс. Коллагеновый фиброз не тождествен амилоидозу и не имеет его специфических свойств.'),
  (E'4ef9d36d-01c9-409d-b702-f1d00d0f00b5', E'72a7c9b3-5ee1-4220-ba8e-c8c945545572', E'AL-амилоид формируется из лёгких цепей иммуноглобулинов, продуцируемых клональными плазматическими клетками; он может сопровождать множественную миелому и другие плазмоклеточные дискразии. AA-амилоид связан с сывороточным амилоидом A при хроническом воспалении. β2-микроглобулин накапливается при длительном гемодиализе. Транстиретин образует отдельные наследственные и возрастные формы амилоидоза. Различение белка-предшественника важно, поскольку клиническое течение и лечение зависят от типа амилоида.');
INSERT INTO public.question_answers (question_id, correct_option_id, explanation) VALUES
  (E'1967d615-d60e-44a0-8dd1-f8ce84258120', E'fc9c0a1b-7aee-4299-bb49-7ce921046a5f', E'При почечном амилоидозе амилоид откладывается в мезангии и капиллярных петлях клубочков, а также в стенках сосудов и иногда интерстиции. Нарушение фильтрационного барьера вызывает выраженную протеинурию, нередко нефротический синдром, а при прогрессировании — хроническую почечную недостаточность. Изолированное канальцевое поражение не типично для классической картины. Казеозный некроз не является проявлением амилоидоза. Линейное свечение IgG указывает на другой иммунопатологический механизм.'),
  (E'59c2d1b6-5243-4a85-b1ab-ed9329d31df5', E'f511f54f-af9e-4a37-aa3e-a0255e95e4e4', E'При выраженном амилоидозе печени внеклеточные отложения в пространстве Диссе и стенках сосудов могут приводить к увеличению органа, повышенной плотности и восковидному виду на разрезе. Это не обязательно сопровождается циррозом. Казеозные узлы относятся к специфическим инфекционным процессам, а мелкозернистая поверхность характерна для узловой перестройки при циррозе. Жировая дистрофия — внутриклеточное накопление липидов и имеет иной механизм и морфологию.'),
  (E'e7cfce69-a32d-4889-b5d6-59f0d7752888', E'1c828ec4-da56-4b46-9132-55d13c1f7808', E'Амилоидные фибриллы откладываются между кардиомиоцитами и в стенках внутримышечных сосудов, делая миокард плотным и менее податливым. Развивается рестриктивная кардиомиопатия с нарушением диастолического наполнения, возможны аритмии и сердечная недостаточность. Накопление гликогена — другой процесс и не объясняет системный амилоидоз. Иммунокомплексное гранулематозное разрушение клапанов не является типичным механизмом. Поражение не ограничивается эпикардом.'),
  (E'11070d93-4d11-4a50-ad30-76daf424a125', E'58394982-40ee-446a-8dea-a9d4512fa2a4', E'AA-амилоидоз развивается при длительном повышении белка сывороточного амилоида A — белка острой фазы, синтез которого усиливается под влиянием провоспалительных цитокинов. При хронической воспалительной стимуляции его фрагменты могут неправильно сворачиваться и формировать амилоидные фибриллы. IgE-зависимый ринит не вызывает такого устойчивого подъёма SAA. Дефицит витамина C приводит к нарушениям синтеза коллагена, а антитела к базальной мембране вызывают иной тип почечного повреждения.'),
  (E'0b201ff5-6e74-4264-8f1f-a73a9831922e', E'7fc153e4-ac83-4a7f-b198-23c649c857b6', E'Современная классификация опирается прежде всего на белок, из которого образованы фибриллы: AL, AA, ATTR и другие типы имеют разные причины и требуют разного подхода к лечению. Например, при AL важно выявить плазмоклеточный клон, а при AA — контролировать хроническое воспаление. Масса органа, лихорадка и макроскопический цвет не позволяют достоверно определить тип амилоида. Морфология и окраски подтверждают наличие амилоида, но типирование белка необходимо для этиологической классификации.'),
  (E'220f6034-a2c2-4697-b9bb-4e6c7ca2ef69', E'76d2ed36-ed71-4b8f-b2fb-6143aad25bb8', E'Гиперчувствительность замедленного типа опосредована T-лимфоцитами. После распознавания антигена они выделяют цитокины, которые привлекают и активируют макрофаги, а в некоторых реакциях цитотоксические T-клетки непосредственно повреждают клетки-мишени. Анафилаксия зависит от IgE и тучных клеток. Антителозависимая цитотоксичность относится к II типу, а иммунокомплексный васкулит — к III типу. Различение этих механизмов важно, поскольку морфология и временная динамика тканевой реакции различаются.'),
  (E'a2f1d89a-8a27-4530-a7dd-94b8bf0e1df4', E'52e3ba00-ebf9-4b4b-8816-96059ea03a97', E'Системный амилоидоз вызывает клинические последствия в зависимости от распределения и объёма депозитов. При поражении сердца возможны рестриктивная кардиомиопатия, нарушения проводимости и сердечная недостаточность; при поражении почек — протеинурия, нефротический синдром и прогрессирующая почечная недостаточность. Разрыв селезёнки не является универсальным или типичным исходом. Амилоидные отложения способны существенно нарушать функцию органов, а анафилаксия не относится к обязательным причинам смерти при амилоидозе.'),
  (E'f2e397a6-7c91-4cac-93a2-657b6067c283', E'417a4cdb-5eb8-4a8a-a5e4-d46d615f0a89', E'Классическая схема связывает I тип с IgE и тучными клетками, II тип — с антителами против клеточных или тканевых антигенов, III тип — с иммунными комплексами, IV тип — с T-клеточными механизмами. Вариант 1 меняет местами механизмы почти всех типов. Вариант 3 также неверно распределяет цитотоксичность, иммунные комплексы и IgE. Вариант 4 перечисляет морфологические исходы, а не иммунологические механизмы, поэтому не может служить классификацией гиперчувствительности.'),
  (E'3d168020-a5d4-4f22-8fb5-e8f8d2370971', E'd72b2d1f-c627-47a9-9661-7c26192aecf9', E'Хроническое воспаление поддерживает высокий уровень сывороточного амилоида A. При определённых условиях его фрагменты формируют AA-амилоид, который откладывается во внеклеточном матриксе, в том числе в клубочках и сосудистых стенках почек. Это нарушает фильтрационный барьер и приводит к протеинурии; по мере накопления депозитов почки могут увеличиваться и уплотняться. Антитела к рецептору ТТГ вызывают функциональную стимуляцию щитовидной железы. IgE и дефицит CD4+ не объясняют образование AA-фибрилл.'),
  (E'3a1991dd-8147-4090-92c6-629b10a22708', E'31b1c774-d5e5-4979-bb14-0f2696bc2a6e', E'Эозинофильный внеклеточный материал на обычной окраске может вызвать подозрение на амилоид, но подобный вид имеют и другие белковые отложения или гиалинизированные структуры. Для подтверждения используют конго красный с оценкой двулучепреломления; затем важно определить тип белка с помощью иммуногистохимических или протеомных методов, если они доступны. Одна окраска H&E не позволяет установить AL-тип. Не всякий эозинофильный материал является амилоидом, а морфология остаётся центральной частью диагностики.'),
  (E'650dd3e8-a68e-490e-aac0-18791bee1faa', E'06482f94-8128-4a5a-beb6-a37013655239', E'Хотя аутоиммунитет и иммунодефицит концептуально различаются, некоторые первичные иммунные дефекты нарушают не только защиту от инфекций, но и механизмы центральной или периферической толерантности. В результате у пациента могут одновременно возникать инфекции и аутоиммунные проявления. Полное отсутствие иммуноглобулинов не является универсальной причиной аутоиммунитета. Повышенная реактивность тучных клеток относится к аллергическим механизмам и не определяет иммунодефицит.'),
  (E'570e7423-0453-4926-aba2-1da8d57f1dfc', E'40069420-4080-481e-948f-d6b34fb73ec2', E'Клеточно-опосредованное повреждение обычно сопровождается инфильтрацией T-лимфоцитами, продукцией цитокинов, активацией макрофагов и иногда прямым цитолизом клеток-мишеней. Гранулярные иммуноглобулины с комплементом указывают на иммунокомплексный механизм III типа. Линейное свечение IgG поддерживает антитела против фиксированного антигена базальной мембраны, то есть II тип. Немедленный отёк и дегрануляция тучных клеток характерны для I типа гиперчувствительности.'),
  (E'f182b2bb-a787-409b-b7e6-4b41f91d1809', E'654495bb-e350-450f-93f0-1953d50ac24c', E'Амилоид может откладываться в клубочках, миокарде, печени, селезёнке, нервах и других структурах, поэтому клинические проявления зависят от того, какие элементы органа вовлечены. Даже умеренное поражение критически важных структур, например проводящей системы сердца или клубочкового фильтра, может иметь существенные последствия. Депозиты не ограничиваются сосудами. Органы различаются по уязвимости, а функциональная недостаточность может развиваться без массивного некроза.'),
  (E'c1c089aa-0e96-436b-89c0-d7a63dc73cad', E'60256fbd-1bfc-41c8-b9ad-d741a4d5c6c5', E'При I типе аллерген активирует IgE-сенсибилизированные тучные клетки, что приводит к выбросу гистамина, лейкотриенов и других медиаторов. Они вызывают повышение сосудистой проницаемости, вазодилатацию, сокращение бронхиальной мускулатуры и секрецию слизи; в позднюю фазу могут накапливаться эозинофилы. Линейное IgG и полулуния связаны с анти-БМК-процессом. Иммунные комплексы и фибриноидный некроз характерны для некоторых реакций III типа, а казеозные гранулёмы — для специфического хронического воспаления.'),
  (E'4c72a3b9-9728-4f57-b806-5c14e2da9c65', E'8a850071-4e02-4d9c-9ec6-2f9381f3eb40', E'Оценка иммунодефицита требует учитывать тип, тяжесть, частоту и возбудителей инфекций, возраст начала, семейный анамнез, лекарства, хронические заболевания и нутритивный статус. Лабораторно исследуют иммуноглобулины, субпопуляции лимфоцитов и при необходимости функциональные тесты фагоцитов или комплемента. Одни лишь частые простуды неспецифичны. Аутоантитела могут встречаться при разных состояниях и не доказывают комбинированный иммунодефицит. Лимфаденопатия также имеет множество причин.'),
  (E'514d2ef7-f521-4743-9165-8d6838ac4cf5', E'24d8024d-c054-4f80-a19c-53d680e4b791', E'При AL-амилоидозе клон плазматических клеток продуцирует моноклональные лёгкие цепи иммуноглобулинов. Часть этих белков неправильно сворачивается и формирует внеклеточные амилоидные фибриллы. Отложения в клубочках, сосудах и интерстиции нарушают фильтрацию и могут вызывать протеинурию, нефротический синдром и прогрессирующую почечную недостаточность. Плазматические клетки не превращаются в эпителий канальцев. IgE не является предшественником AL-амилоида, а бактериальный пиелонефрит — другой патологический процесс.'),
  (E'4722c087-b209-459e-b109-b9b2fd8459f7', E'9dc97a06-22b4-404f-9f41-92879b3d1ccc', E'Сосудистые стенки и клубочки особенно уязвимы к отложению циркулирующих иммунных комплексов из-за особенностей кровотока, фильтрации и взаимодействия с компонентами матрикса. После активации комплемента привлекаются нейтрофилы, высвобождающие протеазы и активные формы кислорода, что повреждает эндотелий и базальные мембраны. Стимуляция рецепторов без воспаления описывает отдельные антителозависимые эффекты, но не иммунокомплексный механизм. Тучные клетки и T-лимфоциты не превращаются в амилоид.'),
  (E'23f183a7-915c-41ef-8bdc-5abae949f3d7', E'5d20dbf3-e319-4144-a6a2-3fc04cff315f', E'Аутоантитела могут быть важными диагностическими маркерами, но не каждое из них непосредственно вызывает повреждение. Патогенность зависит от того, распознаёт ли антитело функционально важную мишень, активирует ли комплемент, вызывает ли цитотоксичность или изменяет работу рецептора. Например, антитела к рецептору ТТГ могут стимулировать функцию, а анти-БМК-антитела повреждают базальные мембраны. Утверждение, что все аутоантитела обязательно разрушительны, слишком категорично; при этом они сохраняют важную диагностическую ценность. Патогенность не ограничена IgE.'),
  (E'3c9d35e3-1e71-4e92-912a-def790bf9fb0', E'5d594902-1a4a-44e3-b82d-70f248886499', E'Фибриноидное набухание бывает локальным или системным. Системное поражение встречается при иммунопатологических заболеваниях, локальное — например, в дне хронической язвы; распространённость определяется причиной и характером повреждения сосудов и соединительной ткани. Процесс не ограничен жировой тканью и может поражать соединительную ткань сосудов и других органов; он не всегда обратим при глубоком повреждении; амилоидоз — отдельный процесс отложения амилоида, а не разновидность фибриноидного набухания. Локальность или системность определяется характером основного заболевания и распространённостью поражения соединительной ткани и сосудов. Например, системные изменения возможны при иммунопатологических заболеваниях, тогда как локальный очаг может формироваться в зоне хронического повреждения. Эта характеристика описывает распространённость процесса, а не его химический состав; амилоидоз имеет собственный механизм накопления патологических фибриллярных белков.'),
  (E'45c1ee9a-1b90-4c78-ac7c-9a82243126ed', E'92077f34-0332-4076-9266-a05a82a5698d', E'При сахарном диабете в стенках мелких сосудов развивается липогиалиноз — вариант гиалиноза, связанный с поражением микроциркуляторного русла. Он способствует утолщению стенок капилляров и артериол и лежит в основе части проявлений диабетической микроангиопатии. Фибрин — белок свёртывания крови и может откладываться при повреждении, но не является видом гиалина; амилоид AL образуется из лёгких цепей иммуноглобулинов; эластин — структурный компонент волокон, а не липидсодержащий гиалин сосудистой стенки. Термин «липогиалин» используют для описания гиалиновых изменений мелких сосудов при диабете, при которых наряду с белковыми компонентами присутствуют липидные компоненты. Диабетическая микроангиопатия затрагивает капилляры и артериолы и может нарушать кровоснабжение сетчатки, почек и других тканей. При этом конкретные микроскопические изменения сосудов зависят от длительности диабета и степени метаболического контроля.'),
  (E'45f13b67-a42a-4ba9-9cea-bfac1eb5c9cf', E'e91457a4-9f7f-45e1-9741-7d6dc1fa309e', E'Увеличение жировой массы при ожирении происходит за счёт гипертрофии адипоцитов — накопления в них большего количества триглицеридов и увеличения объёма клеток, — и/или гиперплазии, то есть увеличения числа адипоцитов. Эти механизмы могут сочетаться, а их соотношение зависит от характера и длительности ожирения. Накопление липидов в клетках печени, миокарда или других паренхиматозных органов относится к жировой дистрофии, а не к увеличению жировых депо. Замещение жировой ткани соединительной тканью само по себе не объясняет увеличение её массы за счёт липидов. Амилоидоз представляет собой внеклеточное отложение патологического белкового материала и не является механизмом развития ожирения.'),
  (E'e02e7800-5760-44b2-a0dd-19dd7489dae0', E'7bbf4acb-33c4-4609-9805-7fec67be6702', E'Тромбоз — прижизненное образование тромботических масс внутри сосуда или полости сердца. Важную роль играют повреждение эндотелия, изменение кровотока и повышение свёртываемости крови. Посмертное свертывание происходит после смерти и обычно не имеет такого прикрепления к стенке. Выход крови в ткани называют кровоизлиянием, а закупорка воздухом относится к эмболии.'),
  (E'e0497c9e-f824-4ac6-8ba8-4fcffd7431a3', E'c4babb61-c4da-4658-86d5-ba3a03a819f6', E'Гиперкоагуляция означает повышенную готовность крови к свёртыванию и бывает наследственной или приобретённой. Она встречается при ряде заболеваний, после операций, при беременности и некоторых опухолях. Потоотделение само по себе не является классическим фактором тромбоза. Подавление тромбоцитов обычно снижает тромбообразование, а увеличение просвета сосуда не означает повышения свёртываемости.'),
  (E'c36acc4d-7f52-4739-913f-ddd3ce0ba647', E'0556c3c7-71a8-4a4d-a54b-e6c8b35cdd4c', E'Прижизненный тромб обычно прикреплён к сосудистой стенке и может иметь слоистое строение — линии Цана. Они отражают чередование тромбоцитарно-фибриновых и эритроцитарных слоёв. Посмертные свёртки чаще свободно лежат в просвете. Фибрин — важный компонент тромба, жир не обязателен, а тромбоз развивается внутри сосудов или полостей сердца.'),
  (E'fbff107e-827e-4b0a-ba88-706157f62887', E'6f842f31-fe8f-4342-a6e9-29bc0cb1eb21', E'При организации тромб прорастает соединительной тканью; внутри могут формироваться каналы, частично восстанавливающие кровоток. Этот процесс называют реканализацией. Он не всегда возвращает сосуду исходный просвет. Тромбоэмболия возникает при переносе оторвавшегося фрагмента, септический распад связан с инфицированием, а кровоизлияние означает выход крови из сосудов.'),
  (E'cbb8c66c-c6be-4358-88a2-b0f62786df4a', E'a4090ada-1f90-4d56-b6a4-a295a6dfa0fc', E'Инфицированный тромб может распадаться, а микроорганизмы и фрагменты разносятся кровью. В органах могут возникать гнойные очаги и абсцессы, поэтому осложнение опасно распространением инфекции. Полное восстановление просвета не обязательно, уровень альбумина не определяет распад, а превращение тромба в лимфатический узел невозможно.'),
  (E'b7512588-538c-4fd0-98d5-5b9f2497288c', E'5aee663a-2ad4-4e52-94c1-2ae01baaa3c6', E'Ретроградная эмболия характеризуется движением эмбола против обычного направления кровотока, что возможно при определённых гемодинамических условиях и под действием силы тяжести. Ортоградный эмбол перемещается по току крови. Растворение без перемещения не вызывает эмболии, а выход плазмы в ткань связан с формированием отёка.'),
  (E'30811497-d642-4191-9e9d-6d128f95330c', E'89f05e47-00c6-4d51-b981-258f27e60469', E'Жировая эмболия часто возникает после переломов длинных костей или обширной травмы. Поражение капилляров лёгких вызывает дыхательную недостаточность, а вовлечение сосудов мозга — неврологические симптомы; иногда появляется петехиальная сыпь. Хронический кашель без связи с травмой неспецифичен, а изолированное увеличение печени и амилоидоз почек не являются типичными проявлениями.'),
  (E'a3c12f47-a8ba-4147-883a-29a093272ecb', E'0478448b-84d1-4e00-9b9a-f96834f74d00', E'Микробная эмболия связана с переносом микроорганизмов или инфицированного материала, например фрагментов вегетаций при инфекционном эндокардите. В месте закупорки могут развиваться гнойные очаги и абсцессы. Жировые капли вызывают другой вид эмболии, а атеросклеротические бляшки формируются в стенке сосуда. Выход плазмы в ткани приводит к отёку, а не к эмболии.'),
  (E'dfd5b93f-110b-4888-a7a7-a584e0ec6d6d', E'a317ff7a-4889-4bd7-9983-259d81179cde', E'Большинство клинически значимых тромбоэмболий лёгочной артерии связано с тромбами глубоких вен ног или таза. Фрагмент проходит через нижнюю полую вену и правые отделы сердца, после чего попадает в лёгочную артерию. Закупорка крупного ствола может резко перегрузить правый желудочек. Лимфатические тромбы, кальцифицированные узлы и подкожные кровоизлияния не являются типичными источниками ТЭЛА.'),
  (E'6614b0e2-6f6c-4f67-abc2-5571a009c41b', E'5189a65d-3251-4558-9057-482bfaed93b8', E'При массивной ТЭЛА правый желудочек внезапно сталкивается с повышенным сопротивлением в лёгочном русле и может остро расширяться. В отличие от хронической перегрузки, времени для выраженной компенсаторной гипертрофии нет. Гипертрофия левого желудочка связана с длительной нагрузкой давлением, а амилоидоз миокарда — самостоятельный процесс. При тяжёлой эмболии гемодинамические изменения могут быть выраженными.'),
  (E'aa662832-6cea-4642-9fbb-a210f1a00a89', E'7f347672-c816-4a3c-a138-e6799d5a5c1c', E'Триада Вирхова объединяет три главных условия тромбообразования: повреждение эндотелия, нарушение кровотока и гиперкоагуляцию. Повреждение сосудистой выстилки активирует тромбоциты, застой облегчает их взаимодействие, а повышенная свёртываемость ускоряет образование фибрина. Температурные и глюкозные нарушения не составляют классическую триаду. Лимфоотток и число эритроцитов не объясняют её основные механизмы.'),
  (E'cd9dc367-e6cf-4135-8882-6e3c807954a2', E'48efb20e-2b6d-4017-b26e-bed0ca809aaa', E'Белые тромбы чаще образуются в артериях при быстром кровотоке и повреждении эндотелия. Они состоят преимущественно из тромбоцитов и фибрина и прикреплены к стенке. Красные тромбы содержат больше эритроцитов и характернее для венозного застоя. Посмертный сгусток не является прижизненным тромбом, а воздушный пузырёк относится к эмболам.'),
  (E'1f31428c-d883-4f63-9cc7-ea80eb2154ec', E'da4ae499-c1fc-4005-ab87-c7bcd34766d6', E'Пристеночный тромб прилежит к стенке сосуда или полости сердца, оставляя часть просвета свободной. Он может возникать в аорте, крупных артериях и камерах сердца при повреждении стенки или замедлении кровотока. Полностью закрывающий просвет тромб называют обтурирующим. Посмертный сгусток не является прижизненным тромбом, а лимфатический узел не соответствует месту образования сосудистого тромба.'),
  (E'f0da8d90-37b8-42b7-a0c3-108bfe574580', E'd7912aa3-6fc2-454e-a2a4-a39d068b36e5', E'Петрификация означает отложение солей кальция в старом тромбе, из-за чего он уплотняется. Кальцифицированные массы могут длительно сохраняться в сосуде. Прорастание соединительной тканью относится к организации, а растворение тромба связано с фибринолизом. Газ не является обычным продуктом превращения тромботических масс.'),
  (E'f0e50622-bf6b-48fb-9c00-29f8fc4ae035', E'ac5356ff-6b33-4160-9f42-3a58cd2f9185', E'Эмболия возникает, когда тромб, жир, газ, тканевые частицы или другой материал переносится кровью и закупоривает сосуд. Место закупорки обычно отличается от места происхождения эмбола. Тромбоз означает образование тромба внутри сосуда или сердца. Выход плазмы в ткани вызывает отёк, а расширение артерии само по себе не является эмболией.'),
  (E'a93c1202-230b-469e-9a1b-d9101ec440a8', E'b99506e9-1dae-4fb2-b182-7fc668911958', E'Парадоксальная эмболия возможна, когда венозный эмбол попадает в системные артерии через патологическое сообщение, например открытое овальное окно при подходящих условиях давления. Тогда могут возникать инфаркты мозга, почки или других органов. Без такого сообщения венозный эмбол обычно направляется в лёгочную артерию. Нарушение лимфооттока и онкотическое давление не обеспечивают переход эмбола между кругами.'),
  (E'fdf7ffca-2171-4586-af41-1032963e99ea', E'cf6ef1d3-3f1d-4d41-bb30-ee7307b39933', E'Воздушная эмболия возникает, когда воздух попадает в сосудистое русло, например при повреждении крупных вен или осложнениях внутрисосудистых процедур. Пузырьки могут препятствовать кровотоку. Венозный застой сам по себе не означает поступления воздуха. Петрификация — отложение кальция в тромбе, а гемолиз в селезёнке не является причиной воздушной эмболии.'),
  (E'b17d1c70-7852-40b0-87e9-9ef244482129', E'df67aa75-d6fd-408e-8759-e2c209a307b4', E'Тканевая эмболия возникает, когда тканевые фрагменты или клетки переносятся кровью в другие органы. Опухолевые клетки могут оседать в удалённых тканях и давать начало метастазам. Воздух вызывает воздушную эмболию, а растворённый альбумин нормально переносится плазмой. Нормальные тромбоциты без патологических агрегатов не являются эмболами.'),
  (E'83f49613-45b3-4d3e-a794-06077996abeb', E'48ba6b16-bc50-406e-b7ba-c27fa417c7f9', E'Массивная тромбоэмболия резко уменьшает доступное сосудистое русло лёгких и повышает сопротивление в малом круге. Правый желудочек испытывает внезапную перегрузку, расширяется и хуже выбрасывает кровь; артериальное давление может падать. Это может привести к острой сердечно-сосудистой недостаточности. Нагрузка не снижается, кровоток через закрытые сосуды не усиливается, а хронический бронхит не является обязательным исходом.'),
  (E'8d34ada7-a9a9-4cfd-a4ae-addebe33a183', E'c0706ba4-6f18-4416-9579-cbdd153101ee', E'Лёгочная ткань получает кровь из лёгочных и бронхиальных артерий. Поэтому закупорка небольшой ветви лёгочной артерии не всегда приводит к некрозу: бронхиальное кровоснабжение может поддержать жизнеспособность ткани. Инфаркт вероятнее при сердечной недостаточности или нарушении дополнительного притока. Капилляры в лёгком многочисленны, венозная кровь поступает в лёгочную артерию, а эмбол не обязательно растворяется сразу.'),
  (E'806f8df1-e29a-4a7a-add3-21468cc9bbee', E'11c6f663-67be-4221-9c99-f8a8a5c6f1ae', E'При разрыве или изъязвлении бляшки кровь контактирует с тромбогенными структурами стенки, активируются тромбоциты и свёртывание. Тромб может резко сузить или закрыть артерию. Сохранный эндотелий обычно препятствует тромбообразованию. Лимфодренаж не запускает этот процесс, а снижение фибриногена затрудняет образование фибринового каркаса.'),
  (E'c3fef176-1576-45bf-98be-9d21b59b0917', E'ab71d49a-a9aa-4c67-a75d-c296f71b2c4c', E'В венах кровоток медленнее, поэтому венозные тромбы обычно красные: фибриновая сеть удерживает большое количество эритроцитов. Они могут быть протяжёнными и распространяться вдоль вены. Белые тромбы типичнее для артерий. Кальций может откладываться в старом тромбе при петрификации, но не составляет его исходную основу; воздух вызывает эмболию, а не тромбоз.'),
  (E'9fde21fe-622f-4576-ba41-a15d02fea248', E'4139b8ff-3b0f-4db8-ae8d-c2e6dae1aba3', E'После инфаркта участок миокарда сокращается хуже, а эндокард над ним может повреждаться. Замедление движения крови и изменение поверхности эндокарда создают условия для пристеночного тромба, особенно в левом желудочке. Его отрыв может вызвать эмболию артерий мозга, почек и других органов. Перикардиальная полость находится вне камер сердца, а здоровое правое предсердие не является единственным местом образования таких тромбов.'),
  (E'1232583a-c69c-4f00-995d-76343dd4f368', E'881c8271-7d5b-4c92-8cac-4ba83977d046', E'Отделившийся фрагмент тромба переносится кровью и может застрять в сосуде меньшего диаметра, перекрыв кровоток. Это называется тромбоэмболией; последствия зависят от локализации. Реканализация — образование каналов внутри организующегося тромба, петрификация — отложение кальция, организация — замещение тромба соединительной тканью.'),
  (E'8335ee21-5584-4b75-b243-20eca12aa1f1', E'fb6d757d-0153-4ceb-b574-dd1cb9039c99', E'При ортоградной эмболии эмбол движется по обычному направлению кровотока и застревает в сосуде меньшего диаметра. Например, венозный тромб может пройти через правые камеры сердца в лёгочную артерию. Движение против тока крови называют ретроградным, а переход из венозного русла в системные артерии через патологическое сообщение — парадоксальным.'),
  (E'a6012c5b-49a2-4c75-898b-66c4a703bb88', E'864b0d3c-861b-4c0f-8520-8823f6777d9a', E'При переломах длинных костей жир костного мозга может попадать в повреждённые сосуды и разноситься кровью. Жировые капли закупоривают мелкие сосуды, особенно лёгких, и могут вызывать дыхательные и неврологические нарушения. Кальцификация — другой процесс, воздух не попадает в кровь при обычном дыхании, а изменение числа тромбоцитов не объясняет механизм жировой эмболии.'),
  (E'16785903-7360-4449-ad97-0d4638f0ec7a', E'69c5e935-644e-4f30-876a-e6c2975accf3', E'При быстром снижении внешнего давления растворённые в крови и тканях газы, прежде всего азот, могут образовывать пузырьки. Они нарушают микроциркуляцию и повреждают ткани. Воздушная эмболия обычно связана с непосредственным попаданием атмосферного воздуха в сосуд. Скопление эритроцитов не является газовой эмболией, а бактерии вызывают инфекционные осложнения.'),
  (E'1a24345e-a94a-47c1-8dcb-a975babf76d5', E'61a4aada-14ea-4b12-8d3d-3b4a3d36639a', E'При попадании в сосуды частиц внешнего материала, например во время травмы или медицинских манипуляций, они могут перекрыть просвет и нарушить кровоснабжение. Физиологическое расширение артериол регулирует кровоток, но не вызывает эмболию. Повышение фибриногена без образования и переноса частиц не создаёт эмбол, а лимфоотток не закупоривает кровеносные сосуды.'),
  (E'0b0a2985-7e1d-45b8-bbb4-a37aea86c53d', E'c2508fe3-b022-46f6-a77b-c2b9b340ded0', E'При массивной ТЭЛА давление в лёгочной артерии быстро повышается, и правый желудочек не успевает адаптироваться. Он расширяется, сократительная функция ухудшается, а наполнение левого желудочка может снижаться. Это уменьшает сердечный выброс и артериальное давление. Гипертрофия левого желудочка связана с длительной перегрузкой большого круга, плеврит поражает плевру, а воздух в перикарде — другое состояние.'),
  (E'1f40cfac-ad88-446a-bbd9-1a645e6c8c9a', E'496e42eb-d45d-4b73-97c6-79d82633f175', E'Тромбоэмболический синдром включает проявления переноса тромботических масс в сосуды разных органов. В зависимости от локализации возникают ТЭЛА, ишемический инсульт, инфаркты почек, селезёнки или кишечника. Повторные эмболии могут вызывать множественные очаги ишемии и некроза. Синяк является кровоизлиянием, а изолированная гипертензия или нарушение лимфооттока без сосудистой закупорки не определяют синдром.'),
  (E'bdd58325-ea1a-4196-8521-4d5310f3826f', E'001ce029-4101-4cda-bb10-322c2a5487a2', E'Эмбол в ветви почечной артерии резко уменьшает приток крови к участку почки. Из-за особенностей артериального кровоснабжения может сформироваться ишемический инфаркт, часто клиновидной формы. Венозное полнокровие всех органов не является прямым следствием локальной эмболии. Жировая дистрофия печени не связана с этим механизмом, а длительное прекращение кровотока угрожает повреждением ткани.'),
  (E'21b90020-3fe5-4635-992a-ddbb2ba5d124', E'85bc3680-f836-405f-8175-fdd830a6edd0', E'Обтурационная ишемия развивается при механическом сужении или закрытии артерии тромбом, эмболом или бляшкой. Приток крови уменьшается, возникает гипоксия, а при тяжёлом и длительном нарушении может сформироваться инфаркт. Ангиоспастическая ишемия обусловлена сокращением сосудистой стенки, венозная гиперемия — затруднением оттока, а геморрагическая инфильтрация означает скопление крови в ткани.'),
  (E'ffa3703e-ad56-47a8-a009-23333aee19fe', E'ed498212-f3c4-4239-9da5-16cab8a06339', E'Гиалиноз — образование в тканях плотных однородных белковых масс. В стенках сосудов гиалин утолщает стенку и может суживать просвет, ухудшая кровоснабжение; в соединительной ткани он делает её плотной и малоподатливой. Нейтральный жир, соли кальция и гликоген представляют другие вещества и соответствуют липидным, кальциевым и углеводным нарушениям. Гиалиноз определяется образованием плотных однородных белковых масс в тканях. Гиалиноз может развиваться в стенках сосудов и в соединительной ткани; внешний вид гиалина не означает, что он является отдельным нормальным анатомическим веществом. Сосудистый гиалиноз утолщает стенку и уменьшает эластичность сосуда, а при выраженном процессе сужение просвета нарушает перфузию. Его следует отличать от амилоида, который выявляют специальными гистохимическими методами, включая окраску конго красным.'),
  (E'586542ea-a8c8-4818-b995-40e0d240e3fc', E'09509f82-4726-4609-bcee-28d80c69fe7e', E'При длительной гипертонии повреждается сосудистая стенка и повышается её проницаемость. Белки плазмы пропитывают стенку, что приводит к её уплотнению и гиалинозу; сужение просвета мелких артерий повышает риск хронической ишемии тканей. Недостаток витамина C вызывает нарушение синтеза коллагена, но не является типичным механизмом простого сосудистого гиалиноза при гипертонии; меланин — пигмент; гликоген в гепатоцитах относится к углеводному обмену и не объясняет изменения сосудистой стенки. Повреждение эндотелия и повышение проницаемости позволяют белкам плазмы проникать в сосудистую стенку; повторяющееся воздействие высокого давления поддерживает этот процесс. В результате стенка становится плотной, утолщённой и менее эластичной, а просвет может суживаться. Дефицит витамина C нарушает образование коллагена, но не объясняет типичный механизм гипертонического гиалиноза.'),
  (E'd5092a77-c826-4581-8899-360e5bbf2626', E'c2665811-d0fb-4b5a-99ed-40b9254bd8c7', E'Первая степень ожирения соответствует превышению возрастной нормы массы тела на 20–29%. Эта градация относится к традиционной классификации по проценту превышения нормативной массы; в современной клинической практике у взрослых обычно используют индекс массы тела. Превышение на 5–10% и 10–19% ниже диапазона, принятого в данной классификации для первой степени; 50–99% соответствует более высокой степени. Важно, что здесь используется традиционная процентная градация, а не современная классификация взрослых только по ИМТ. Эта процентная градация относится к традиционной учебной классификации и не должна автоматически переноситься на современные клинические критерии диагностики ожирения у взрослых. В клинической практике обычно используют индекс массы тела, окружность талии и оценку связанных с ожирением осложнений. При ответе на вопрос важно следовать именно указанному в формулировке критерию — проценту превышения возрастной нормы массы тела.'),
  (E'a31d4950-4f04-4bb4-a905-d6694a14cd0d', E'3842251c-e813-4dba-9242-28165859d306', E'Ишемия означает уменьшение притока артериальной крови, из-за чего ткань получает меньше кислорода и питательных веществ. Исход зависит от тяжести и длительности нарушения, потребности ткани и коллатерального кровотока. Венозное полнокровие связано с нарушением оттока, кровоизлияние — с выходом крови за пределы сосудов. Тромбоз может вызвать ишемию, но не является её определением, поскольку существуют и другие причины.'),
  (E'd68ca4c2-0710-4578-937f-f2d791435499', E'62c05926-c829-4bd8-811b-682bd3871d53', E'Некроз зависит от тяжести и длительности ишемии, потребности клеток в кислороде и наличия коллатерального кровоснабжения. Нервная ткань особенно чувствительна к гипоксии, поэтому тяжёлая ишемия мозга быстро вызывает необратимые изменения. Кратковременное снижение кровотока может быть обратимым. Цвет кожи не определяет исход, а лимфатические сосуды и отёк не заменяют оценки артериального притока.'),
  (E'0f094078-4297-4209-b19e-5216d4dfa3ed', E'9fde0c26-8812-4b24-8726-8fdc6b57b77e', E'Простой гиалин может откладываться в стенках мелких артерий и артериол при гипертонической болезни вследствие повреждения сосудистой стенки и пропитывания её белками плазмы. Стенка становится утолщённой и однородной, просвет сосуда суживается, что может ухудшать кровоснабжение органов. AA-амилоид — отдельный тип амилоида, а не вариант гиалина при гипертонии; кератогиалин находится в эпидермисе и связан с ороговением; коллоид щитовидной железы — содержимое фолликулов, а не гиалин сосудистой стенки. Простой гиалин связан преимущественно с пропитыванием сосудистой стенки белками плазмы на фоне её повреждения. Утолщение стенки и сужение просвета особенно значимы в мелких артериях и артериолах, поскольку могут приводить к хронической ишемии органов. Амилоид отличается фибриллярной структурой и характерными результатами специальных окрасок, а кератогиалин относится к процессу ороговения эпидермиса.'),
  (E'08015b62-adc7-4904-b55e-03dac689d054', E'c47d3c46-7b8b-4e99-ba9d-14379f55eb08', E'Сложный гиалин встречается при тяжёлых иммунопатологических заболеваниях; в его образовании участвуют иммунные комплексы и другие белковые компоненты. Такие отложения связаны с иммунным повреждением сосудов и соединительной ткани, а их состав отличается от простого сосудистого гиалина. Старение волос не связано с образованием сложного гиалина в тканях; неосложнённый аппендицит — острое воспаление; жировая дистрофия печени — внутриклеточное накопление липидов. Сложный гиалин связывают с иммунопатологическим повреждением. Сложный гиалин формируется при участии иммунных комплексов и других белковых компонентов, поэтому его связывают с иммунопатологическим повреждением сосудов и соединительной ткани. Его состав и механизм образования отличаются от простого гиалина, возникающего главным образом при пропитывании сосудистой стенки плазменными белками. В диагностике учитывают клинический контекст и морфологию очага, а не только однородный внешний вид материала.'),
  (E'a55c95dd-b473-45df-be46-06afb4a42dc4', E'd8a4f2bb-f2ba-469b-9e40-cbc780dd5f5b', E'Третья степень ожирения соответствует превышению возрастной нормы массы тела на 50–99%. В этой классификации степень определяют по проценту превышения нормы, а не только по внешнему распределению жира. Диапазоны 20–29% и 30–49% соответствуют более низким степеням в данной процентной классификации; 100% и более превышает диапазон, указанный для третьей степени, и относится к ещё более выраженному превышению нормы. В традиционной процентной схеме третья степень соответствует выраженному превышению нормативной массы, но сама по себе эта цифра не описывает распределение жира или тяжесть метаболических осложнений. Современная клиническая оценка включает ИМТ и дополнительные показатели риска. Диапазоны 20–29% и 30–49% соответствуют меньшему превышению нормы, тогда как 100% и более выходит за пределы диапазона третьей степени в этой схеме.'),
  (E'd13cd01e-b99d-4587-92bd-e0d916db1b42', E'6d36d545-a0a1-465e-8f77-4dacea3c9fb6', E'При ангиоспастической ишемии спазм гладкой мускулатуры артерии сужает её просвет и уменьшает приток крови. Спазм может быть связан с нервными, гуморальными или лекарственными воздействиями. Разрыв вены вызывает кровотечение, а усиление венозного оттока само по себе не уменьшает артериальный приток. Петрификация тромба не объясняет спазм без сужения сосуда.'),
  (E'd162be65-291b-44f2-87ab-a37d944272c9', E'2201cfd1-6965-4fa9-85c9-3564c45328be', E'При гиперпластическом типе ожирения увеличивается количество адипоцитов, а их размер может оставаться близким к обычному. Увеличение числа жировых клеток означает расширение жирового депо за счёт формирования дополнительных клеток. Гипертрофический тип характеризуется увеличением размера уже имеющихся адипоцитов; амилоидное отложение и фиброз не являются типами ожирения. При гиперпластическом типе увеличивается прежде всего количество жировых клеток. Гиперпластический механизм связан с увеличением числа адипоцитов, тогда как при гипертрофическом механизме увеличивается объём каждой клетки за счёт накопления триглицеридов. Эти механизмы могут сочетаться, поэтому тип ожирения не всегда определяется исключительно одним параметром. Увеличение количества клеток отражает расширение жирового депо за счёт клеточной численности, а не только за счёт увеличения объёма существующих адипоцитов.'),
  (E'64cfd88c-db39-439e-b605-f01535eccb5f', E'76886e51-e4bc-4745-ad1d-34fec7a700f5', E'При гипертрофическом типе ожирения увеличивается размер адипоцитов из-за накопления в них триглицеридов; этот тип часто связан со снижением чувствительности к инсулину. Крупные адипоциты могут сопровождаться нарушением регуляции липолиза и повышенным риском метаболических осложнений. Уменьшение адипоцитов противоречит гипертрофическому типу; полное исчезновение жировых депо не является ожирением; амилоид не накапливается в адипоцитах как определяющий признак этого типа. Увеличенные адипоциты способны изменять секрецию адипокинов и воспалительных медиаторов, а также нарушать нормальную регуляцию высвобождения свободных жирных кислот. Это способствует инсулинорезистентности и повышает вероятность метаболических осложнений. При гиперпластическом типе основной морфологический признак — увеличение количества клеток, а не их размера; амилоидные отложения не являются механизмом ожирения.'),
  (E'fcb6bd47-f1dc-4837-b132-5954db0b35a1', E'e35ccb02-a950-4b5a-b5a7-564efb5e78a8', E'Гипертрофический тип считают неблагоприятным, поскольку он чаще сопровождается метаболическими нарушениями, включая снижение толерантности к глюкозе. Увеличенные адипоциты связаны с инсулинорезистентностью и повышенным риском развития сахарного диабета 2-го типа. Гиперпластический тип характеризуется увеличением числа жировых клеток, а не их выраженным увеличением в размере; локальный и симметричный описывают распространение или распределение жира, а не два типа по морфологии адипоцитов. Неблагоприятность гипертрофического варианта связывают с метаболической активностью увеличенных адипоцитов и их ассоциацией с инсулинорезистентностью, нарушением толерантности к глюкозе и дислипидемией. Однако индивидуальный риск зависит также от распределения жировой ткани, наследственных факторов и сопутствующих заболеваний. Термины «локальный» и «симметричный» описывают распространённость или распределение жира, а не размер и количество адипоцитов.'),
  (E'aa1adc4c-56a0-4c22-b615-5f625e96e256', E'3ed5d1a4-a5f0-4f5d-8121-b4abc21df0a3', E'При андроидном типе жир преимущественно откладывается в верхней части тела и области живота; при гиноидном — в области бёдер и ягодиц. Абдоминальное, особенно висцеральное, ожирение теснее связано с инсулинорезистентностью и сердечно-сосудистым риском. Саговая и сальная — термины, используемые для описания селезёнки при амилоидозе; периретикулярный и периколлагеновый — варианты расположения амилоида; первичный, вторичный и старческий — формы амилоидоза по происхождению, а не распределение жира. Классификация по распределению описывает топографию жировых отложений, тогда как гипертрофический и гиперпластический типы характеризуют клеточный механизм увеличения жировой массы. Андроидное, или верхнее, распределение обычно связано с преобладанием жира в области туловища и живота; гиноидное — в области бёдер и ягодиц. Особенно важно учитывать висцеральный жир, поскольку он сильнее связан с метаболическими нарушениями, чем подкожный жир в некоторых других областях.'),
  (E'03ea3084-15aa-493a-b432-88adb1e38bdb', E'63a76959-1c80-406c-b516-a1fe68223b38', E'Опухоль — это патологический процесс, в основе которого лежит стойкое изменение генетического аппарата клетки; такие клетки размножаются автономно, не подчиняясь регуляторным сигналам организма, и утрачивают способность к нормальной дифференцировке. Рост сохраняется и после прекращения действия вызвавшего фактора, а опухолевый клон передаёт свойства дочерним клеткам. Именно сочетание автономности, нарушенной дифференцировки и генетической природы делает определение полным. Определение, описывающее обратимое увеличение объёма органа в ответ на нагрузку, относится к гипертрофии: она регулируется, зависит от нагрузки, а при её прекращении орган уменьшается. Накопление жидкости в межклеточном веществе соответствует отёку, при котором клеточного размножения нет. Восстановление ткани с воспроизведением исходной структуры — это репаративная регенерация, регулируемый процесс, который прекращается после замещения дефекта.'),
  (E'7798d804-4674-4970-90d4-e7fc57a05aac', E'ddaed5bc-6da9-4c43-be9f-7be2d42da743', E'В микроскопическом строении любой опухоли различают паренхиму и строму. Паренхима образована собственно опухолевыми клетками и определяет гистогенез, название и основные биологические свойства новообразования. Строма представлена соединительнотканным каркасом, межклеточным веществом, сосудами и нервами; через неё опухоль получает питание, а выраженность стромы влияет на плотность узла. Ответ о том, что в строении остаются только сосуды и воспалительный инфильтрат, неверен: инфильтрат бывает лишь реакцией на опухоль и не заменяет опухолевую паренхиму. Утверждение об одном эпителиальном пласте с обязательной базальной мембраной не подходит, поскольку опухоли бывают не только эпителиальными, а базальная мембрана не является обязательным компонентом: при инвазивном раке она разрушается. Представление о некротическом центре и капсуле как обязательных компонентах ошибочно, так как капсула и некроз встречаются не во всех опухолях.'),
  (E'2615f825-dd7d-4880-b44f-fbee35607643', E'7874e48f-db83-4978-8501-e6502a545ced', E'Термины органоидная и гистиоидная опухоль отражают особенности её архитектуры. В органоидной опухоли сохраняется сложное соотношение паренхимы и стромы, и новообразование напоминает организацию органа: есть выраженный соединительнотканный каркас, сосуды, дольки. В гистиоидной опухоли строма скудна, резко преобладает паренхима, поэтому такие опухоли, например саркомы, растут быстро, склонны к некрозам и кровоизлияниям. Мысль о том, что органоидные опухоли состоят только из стромы, а гистиоидные только из сосудов, неверна: ни один из типов не лишён паренхимы. Ответ, сводящий названия к локализации опухоли, не подходит, потому что эти термины описывают строение, а не место возникновения. Связь органоидности со злокачественностью, а гистиоидности с доброкачественностью также ошибочна: и среди тех, и среди других есть доброкачественные и злокачественные опухоли.'),
  (E'00668165-ca4e-4cb4-9df9-5a0f9fc8cdc8', E'547e26cf-0e86-4acb-9354-678a02d54dd9', E'Тканевый атипизм — это нарушение структуры ткани, в которой развивается опухоль: изменяются соотношения и взаиморасположение паренхимы и стромы, неравномерно развиваются железы, их форма и размеры, при этом сами клетки могут сохранять сходство с исходной тканью. Тканевый атипизм характерен и для доброкачественных опухолей, поэтому сам по себе злокачественность не доказывает. Описание резко увеличенных гиперхромных ядер и патологических митозов относится к клеточному атипизму — изменению формы и размеров клеток и ядер. Обязательные отдалённые метастазы в печени и лёгких характеризуют не строение, а биологическое поведение: метастазы бывают лишь у злокачественных опухолей и не обязательны для тканевого атипизма. Увеличение размера каждой клетки при неизменной архитектуре — это гипертрофия клеток, при которой строение ткани не нарушено, а рост остаётся регулируемым.'),
  (E'e7727bde-ab71-474f-8a77-51f81ab987aa', E'98b1cade-5a89-43b4-bf78-2113cd2ba0fa', E'По происхождению пигменты делят на экзогенные и эндогенные. Внутриклеточная/внеклеточная локализация, наличие железа и растворимость — другие характеристики, поэтому они не отвечают на вопрос о происхождении пигмента. К эндогенным относятся пигменты, образующиеся в организме, например гемосидерин, билирубин, меланин и липофусцин; экзогенные поступают извне, как угольная пыль. Локализация и химический состав помогают уточнить свойства пигмента, но не заменяют классификацию по происхождению.'),
  (E'9c76ce0a-c256-4093-a552-66572aac4663', E'3c904f54-4f63-4056-876f-3d956b4c098d', E'Клеточный атипизм проявляется изменением самих опухолевых клеток: полиморфизмом клеток и ядер, гиперхромией ядер, увеличением ядерно-цитоплазматического отношения, полиплоидией, гигантскими и многоядерными формами, нарушенными патологическими митозами. Чем сильнее выражены эти изменения, тем ниже дифференцировка и, как правило, агрессивнее течение опухоли. Неравномерность соединительнотканных перегородок при почти нормальных клетках описывает тканевый атипизм, а не клеточный. Сохранение полярности эпителия и непрерывной базальной мембраны характеризует ткань без ядерных изменений: это типично для нормального эпителия или неинвазивных высокодифференцированных образований. Формирование капсулы вокруг узла — макроскопическая особенность опухолевого узла, а не свойство клеток, поэтому к клеточному атипизму она не относится.'),
  (E'e02b53cd-28ea-4089-94a7-020741b84974', E'5048e423-014d-481d-bb39-edf31620fd1d', E'Экспансивный рост — это рост опухоли «из себя»: узел постепенно увеличивается и оттесняет, сдавливает окружающие ткани, формируя относительно чёткую границу, иногда псевдокапсулу из сдавленной стромы. Так растут преимущественно доброкачественные опухоли. При инфильтрирующем росте опухолевые клетки проникают между структурами соседних тканей, прорастают сосуды и нервы и разрушают их, границы узла нечёткие; это характерно для злокачественных опухолей. Различие этих типов роста по цвету опухоли на разрезе неверно: окраска не определяет тип роста. Утверждение о том, что экспансивный рост всегда означает быстрое метастазирование, ошибочно, поскольку метастазы не связаны с этим типом роста, а при инфильтрирующем росте они возможны и нередки. Ограничение экспансивного роста эпителием, а инфильтрирующего другой тканью не подходит: тип роста не привязан к одной ткани и встречается в любых тканях.'),
  (E'bf35b774-f86c-45f7-8fdb-a4f73f53ec32', E'6640ea32-85da-46cc-a96e-24a3566029d2', E'Экзофитный рост означает, что опухоль растёт в просвет полого органа, нередко на ножке, формируя полипоподобное образование, при этом основание узла не прорастает глубоко в стенку. Такой тип роста чаще наблюдается у доброкачественных опухолей и ранних форм рака, он хорошо виден при эндоскопии. Периневральное распространение вдоль нервных оболочек — путь инвазии, а не форма роста в просвет органа. Имплантационное распространение означает перенос клеток по серозным оболочкам и образование метастазов, а не рост узла на ножке в просвет. Эндофитный инфильтрирующий рост направлен вглубь стенки: опухоль пронизывает её толщу, а со стороны слизистой может быть малозаметна.'),
  (E'64ec5c12-f0ed-453d-949d-d5d0c8aef162', E'f3f20475-ad37-48db-940e-52cfbf71a44b', E'Доброкачественные опухоли обычно построены из зрелых, достаточно дифференцированных клеток, имеют сходство с исходной тканью, растут медленно и экспансивно, не прорастают окружающие ткани и не метастазируют. Однако их влияние на организм может быть тяжёлым: опухоль в головном мозге, на сосуде или в просвете органа сдавливает структуры и нарушает функцию, а гормонально активные аденомы вызывают эндокринные нарушения. Утверждение о том, что такая опухоль всегда инкапсулирована, никогда не рецидивирует и не нарушает функцию органа, неверно: капсула имеется не всегда, рецидивы возможны, а функция органа может страдать. Выраженный клеточный атипизм и прорастание сосудов характерны скорее для злокачественных новообразований, поэтому для доброкачественной опухоли они не обязательны. Мысль о том, что опухоль по определению не растёт после устранения раздражающего фактора, ошибочна: она растёт автономно и продолжает увеличиваться независимо от исходной причины.'),
  (E'b8304fd1-d0eb-42ca-8c10-cce840f693b7', E'ae894fe3-6781-4473-95de-9a35ee859829', E'Главным признаком злокачественности считают инвазивный, деструирующий рост: опухолевые клетки прорастают в окружающие ткани, сосуды и нервы, разрушая их, и приобретают способность к метастазированию. Именно метастазы отличают злокачественную опухоль от доброкачественной и определяют прогноз. Размер узла не определяет характер опухоли: большими могут быть и доброкачественные новообразования, например лейомиомы или липомы. Плотная строма и белесоватый цвет на разрезе неспецифичны и встречаются в разных опухолях. Тканевый атипизм при полностью сохранённых базальной мембране и полярности описывает зрелую неинвазивную опухоль, а без инвазии рак не диагностируется.'),
  (E'db15c315-a26a-4e09-9fa6-8ae864be9d7c', E'24db1dfd-4c61-43cd-a8fd-f185f10b9e8d', E'Метастазирование — это перенос опухолевых клеток из первичного очага в другие органы и образование вторичных опухолевых узлов. Выделяют лимфогенный путь, при котором клетки распространяются по лимфатическим сосудам в регионарные лимфатические узлы (типичен для рака), гематогенный путь по кровеносным сосудам (характерен для сарком и ряда раков, например почечно-клеточного) и имплантационный путь, при котором клетки переносятся по серозным оболочкам, например по брюшине. Определение метастазирования как появления опухоли на прежнем месте после удаления неверно: это называется рецидивом. Деление путей на лимфогенный по нервным оболочкам и гематогенный только в соседнюю ткань ошибочно: распространение по нервным оболочкам называют периневральным, а гематогенный путь не ограничен соседней тканью. Утверждение, что все злокачественные опухоли распространяются только гематогенно, не подходит: разные опухоли используют разные пути, нередко несколько одновременно.'),
  (E'5803f405-bebb-4140-8a87-eedd26183633', E'87f7fd39-b295-4b99-894c-be243230e8c2', E'Рецидив — это повторное возникновение опухоли в области первичного очага после операции, лучевой или иной терапии. Чаще всего он связан с тем, что в зоне вмешательства сохранились единичные опухолевые клетки или фрагменты опухолевого поля, которые затем дали новый рост. Склонность к рецидивам особенно характерна для инфильтрирующих опухолей без чётких границ. Первичное появление нескольких независимых очагов в одном органе — это не рецидив, такие очаги называют множественными или мультицентричными опухолями. Увеличение лимфатического узла из-за воспаления не связано с опухолевыми клетками и рецидивом не является. Образование дочерней опухоли в отдалённом органе — это метастаз, а не рецидив.'),
  (E'c25f43b6-2cf9-47a7-ad9f-6ed1a987ffe9', E'e9e0f6ce-5796-4e48-8066-48eab1e3b18b', E'Раковая кахексия — системный синдром, который развивается у онкологических больных и проявляется прогрессирующим истощением: потерей жировой ткани и скелетной мускулатуры, слабостью, анемией, снижением аппетита и выраженными нарушениями обмена веществ. Механизм связан с действием опухолевых продуктов и провоспалительных цитокинов, которые изменяют метаболизм, усиливают распад белков и жиров, поэтому масса тела падает даже при достаточном питании. Единичный эпизод сниженного аппетита без потери массы и мышц синдромом кахексии не является. Увеличение мышечной массы вследствие усиленного синтеза белка противоположно кахексии, при которой мышечная масса уменьшается. Локальный отёк вокруг опухоли описывает местный эффект, а кахексия — общее системное нарушение.'),
  (E'20b600f1-adfb-4f62-8402-cf8f981002fc', E'de385de0-0caa-48d4-aa77-a6a562e6e565', E'Паранеопластические синдромы — системные проявления опухолевого процесса, не объясняющиеся непосредственным ростом первичной опухоли или метастазов. Они обусловлены продукцией опухолью гормоноподобных веществ, цитокинов и других биологически активных соединений либо иммунными реакциями: например, эктопическая секреция АКТГ мелкоклеточным раком лёгкого даёт синдром Кушинга, возможны гиперкальциемия, тромбофлебиты, неврологические и кожные изменения. Боль из-за прорастания опухоли в нерв — прямой местный эффект опухоли, а не паранеопластический синдром. Кровотечение из изъязвлённой поверхности связано с разрушением сосудов в зоне роста, то есть тоже с местным действием узла. Увеличение органа за счёт механического заполнения полости — местное следствие объёма опухолевого узла.'),
  (E'177cd05a-c585-4580-9af3-709a3c261183', E'ff6e8ada-d57d-4f4d-aece-95302e9d5379', E'Типичная схема морфогенеза опухоли начинается с нарушения регуляции пролиферации и дифференцировки при хроническом повреждении, воспалении и регенерации. На этом фоне развиваются предопухолевые (предраковые) изменения — гиперплазия, метаплазия, дисплазия, затем опухолевая трансформация клеток (малигнизация), формирование опухолевого зачатка и его прогрессия: клон приобретает автономность, инвазивные свойства и способность к метастазированию. Представление о том, что образование рубца обязательно превращается в рак, неверно: малигнизация возможна лишь в части случаев. Последовательность, в которой метастазирование ведёт к полному восстановлению ткани и исчезновению опухоли, ошибочна: метастазирование — поздний этап, а генетические нарушения опухолевых клеток не исчезают. Цепочка «капсула — некроз — нормальная дифференцировка — физиологическая регенерация» не описывает ни опухолевую трансформацию, ни её стадии, а капсула и некроз не обязательны.'),
  (E'e2947111-bb70-4bfd-8191-adc3ec628c13', E'c4c93a16-51c6-4e54-9207-79ca4b7ef177', E'Гистогенез опухоли — это происхождение опухоли из определённой ткани или клеточной линии. Его устанавливают по морфологической дифференцировке опухолевых клеток: они воспроизводят признаки исходной ткани, например образуют железы, ороговевающие структуры, сосуды, жировые клетки или меланин. При затруднениях применяют иммуногистохимию и другие дополнительные методы. Определение только анатомической глубины инвазии отражает распространённость процесса и стадию, но не клеточное происхождение. Оценка цвета опухоли на разрезе без микроскопии не позволяет определить клеточную линию. Описание скорости увеличения опухоли по дням характеризует динамику роста и биологическое поведение, но не происхождение.'),
  (E'8777347a-f13f-480f-9a01-7692b6304a50', E'31be5580-c697-49d0-82f4-0151018e7ffe', E'Современная гистогенетическая классификация делит опухоли на семь групп по ткани, из которой они развиваются: органонеспецифические эпителиальные опухоли (из эпителия, не выполняющего узкоспециализированной функции), органоспецифические эпителиальные опухоли (из эпителия желёз и органов, обладающих специфической функцией), мезенхимальные опухоли, опухоли меланинобразующей ткани, опухоли нервной системы и оболочек мозга, опухоли системы крови и тератомы. Деление только на доброкачественные, пограничные и злокачественные опухоли отражает биологическое поведение, а не происхождение. Перечень эпителиальных, инфекционных, воспалительных, сосудистых и дегенеративных процессов неверен: инфекционные, воспалительные, обменные и травматические процессы не являются опухолями. Классификация по органам не учитывает ткань, из которой развивается опухоль, а в одном органе могут возникать опухоли разных групп.'),
  (E'00d9f5a1-09e2-498c-b2af-70008e6015a7', E'8164297e-213e-4c6b-9d2d-992ea1847ffc', E'Органонеспецифические эпителиальные опухоли развиваются из плоского, переходного или железистого эпителия, не обладающего узкой органной специализацией, поэтому встречаются в разных органах. К ним относятся папилломы и аденомы, а также рак in situ и инвазивные формы, например плоскоклеточный рак и аденокарцинома. Папиллома из плоского или переходного эпителия — классический пример доброкачественной органонеспецифической опухоли. Почечно-клеточный рак связан со специализированным эпителием почечных канальцев, это органоспецифическая опухоль. Фолликулярный рак щитовидной железы происходит из тиреоидного эпителия, выполняющего специфическую функцию синтеза тиреоглобулина. Опухоль из C-клеток щитовидной железы имеет нейроэндокринную природу и тоже органоспецифична.'),
  (E'8e2c9f36-0991-403f-81de-44e66b77686c', E'1ec41bff-505d-41d5-b5e4-c73ef1cb4f8e', E'Папиллома — доброкачественная опухоль из покровного эпителия, обычно растущая экзофитно. Её основа — сосочковые разрастания, образованные паренхимой из зрелого эпителия и стромой, представленной соединительнотканными выростами с сосудами. Полярность и слоистость эпителия в целом сохранены, базальная мембрана непрерывна, инвазии в подлежащие ткани нет. Образование из одних коллагеновых пучков без эпителиальной паренхимы было бы соединительнотканным, а не папилломой. Инвазивные тяжи атипичных клеток, разрушающие базальную мембрану и проникающие в строму, описывают инвазивный рак. Сплошные пласты анапластических клеток без эпителиальной дифференцировки характерны для злокачественной опухоли, тогда как доброкачественная папиллома, напротив, высоко дифференцирована.'),
  (E'654b5e7e-1813-4329-ae25-b5d5ab6c785f', E'14c135c8-3cde-43dd-afec-939360c4ee8e', E'Аденома — доброкачественная эпителиальная опухоль железистого типа. Её клетки напоминают клетки исходной железистой ткани и образуют железистые структуры: ацинарные, тубулярные, трабекулярные или сосочковые (папиллярные), поэтому по строению различают соответствующие варианты. Опухоль растёт экспансивно, базальная мембрана сохранена, инвазии и метастазов нет, хотя гормонально активная аденома может вызывать эндокринные нарушения. Опухоль из гладкой мышечной ткани, образующая переплетающиеся пучки, — это лейомиома, а не эпителиальная опухоль. Поверхностный дефект эпителия называют эрозией: автономной пролиферации в нём нет. Злокачественная опухоль, прорастающая сосуды и дающая метастазы, — это аденокарцинома, а не аденома.'),
  (E'1c6c9423-df6d-438f-8b53-86535a05a7b2', E'ee7f6cb4-2845-4cbb-8bd1-7fc380e8b354', E'Carcinoma in situ (рак на месте) — ранняя форма рака: атипичные эпителиальные клетки с выраженным клеточным атипизмом, нарушением полярности и многочисленными митозами занимают всю толщу эпителиального пласта или протока, но не прорастают через базальную мембрану в подлежащую строму. Поскольку инвазии нет, сосуды и лимфатические пути не вовлечены, метастазов нет, и после полного удаления прогноз благоприятный; при отсутствии лечения процесс может перейти в инвазивный рак. Утверждение о том, что при carcinoma in situ клетки обязательно находятся в сосудах, неверно: нахождение клеток в сосудах означает инвазию, которой при in situ нет. Мысль о том, что при инвазивном раке базальная мембрана всегда сохранена, ошибочна: при инвазивном раке она разрушена. Отождествление carcinoma in situ с доброкачественной папилломой не подходит, поскольку in situ — злокачественная опухоль с выраженной атипией.'),
  (E'2f9bf124-fa86-4041-a9a6-48429f509b45', E'9481b350-525f-4c0e-8683-21416106f914', E'Плоскоклеточный рак с ороговением образован атипичными клетками плоского эпителия, которые формируют гнёзда и тяжи, инвазирующие подлежащую ткань и разрушающие базальную мембрану. Клетки сохраняют способность к ороговению: в центре гнёзд образуются слоистые массы рогового вещества — раковые жемчужины, видны межклеточные мостики и дискератоз. Правильные железы, выстланные однотипным эпителием без инвазии, описывают аденому или другую доброкачественную железистую структуру. Сосочковые структуры с сохранённой полярностью и неповреждённой базальной мембраной соответствуют доброкачественной папилломе, у которой сосочки покрыты зрелым эпителием. Пласты меланоцитов с синтезом меланина относятся к меланоцитарным опухолям — другой клеточной линии, они происходят из меланоцитов и не являются эпителиальными.'),
  (E'96a6a6a2-568c-4a8e-8c0c-c6f34a01de3a', E'28d1ddba-7570-47e4-9c47-bd070b68d660', E'Аденокарцинома — злокачественная опухоль железистого эпителия. В отличие от аденомы, она демонстрирует клеточный атипизм (полиморфизм, гиперхромию ядер, патологические митозы), нарушение нормальной архитектуры желёз, их беспорядочное расположение и главное — инвазию: опухолевые комплексы прорастают базальную мембрану, строму, сосуды и способны метастазировать. Аденома же дифференцирована и растёт экспансивно, не повреждая базальную мембрану. Мнение, что различие сводится только к цвету на разрезе, неверно: различия определяются микроскопически, а цвет не служит критерием. Утверждение о том, что аденокарцинома состоит из зрелых клеток без митозов и не метастазирует, ошибочно: она состоит из атипичных клеток с митозами и метастазирует. Представление об аденоме как опухоли соединительной ткани не подходит: обе опухоли эпителиальные, а соединительнотканные и мышечные опухоли имеют другое происхождение.'),
  (E'b3b535e2-703f-4cda-89aa-df61c0e4d002', E'b073f768-f66b-433e-a9c0-8eee92bb7434', E'Слизистый (коллоидный) рак — злокачественная железистая опухоль, клетки которой продуцируют избыточное количество слизи. Слизь накапливается в строме и просветах, и опухолевые клетки как бы плавают в слизистых «озёрах»; на разрезе ткань опухоли выглядит слизистой, студенистой, блестящей. Такая опухоль часто встречается в желудке и кишечнике, а также в молочной железе. Опухоль из эндотелия, образующая заполненные кровью полости, — это гемангиома, то есть сосудистая опухоль. Папиллома с ороговением поверхности без слизеобразования не подходит: ороговение характерно для плоского эпителия, а не для слизистого рака, и папиллома не продуцирует слизь в такой степени. Доброкачественная опухоль из зрелых адипоцитов с жировыми вакуолями — это липома, а не эпителиальная опухоль.'),
  (E'35f47150-6595-4c46-8a78-2edad4a3810e', E'2af54a02-1150-476c-a3a1-58c55ab2daa0', E'Анапластический (недифференцированный) рак щитовидной железы состоит из резко атипичных клеток, потерявших признаки тиреоидной дифференцировки: преобладают полиморфные, гигантские, веретеновидные клетки с множеством атипичных митозов, часто обширные некрозы. Опухоль встречается преимущественно у пожилых, растёт очень быстро, прорастает мышцы, трахею, пищевод и сосуды шеи, рано метастазирует, а прогноз крайне неблагоприятен. Папиллома эпидермиса — доброкачественное образование кожи, не имеющее отношения к тканям шеи и щитовидной железе. Доброкачественная инкапсулированная опухоль из однотипных фолликулов без инвазии соответствует фолликулярной аденоме. Опухоль из зрелых адипоцитов — липома — не является опухолью щитовидной железы.'),
  (E'3f6a3d78-bf73-432c-866d-df19aff261d3', E'041d127d-5ea6-4de8-a9ea-b0d595c90dec', E'Главное при разграничении рака молочной железы in situ и инвазивного — наличие или отсутствие прорастания за пределы исходных эпителиальных структур. При протоковом и дольковом раке in situ атипичные клетки лежат внутри протоков или долек, базальная мембрана и миоэпителий сохранены, и метастазов нет. При инвазивном раке клетки разрушают базальную мембрану, проникают в окружающую строму и жировую клетчатку, прорастают сосуды и дают метастазы, что определяет объём лечения. Мысль о том, что рак in situ всегда больше по размеру, чем инвазивный, неверна: размер узла не служит критерием, in situ может быть как мелким, так и протяжённым. Описание, в котором инвазивный рак ограничивается просветом протока, а in situ прорастает окружающую ткань, перевёрнуто: прорастание жировой клетчатки — признак инвазии. Утверждение, что эти формы различаются только наличием боли, ошибочно: их различают гистологически, а не по боли.'),
  (E'4a7279fa-92b9-4911-9c0e-ca41fd6d90e9', E'9c5faf93-760a-4f9e-90a9-4e98919f3b81', E'Болезнь Педжета молочной железы — особая форма рака, которая клинически проявляется экзематозными изменениями соска и ареолы (покраснение, шелушение, корочки, изъязвление). Микроскопически в эпидермисе соска находят крупные светлые опухолевые клетки Педжета с обильной цитоплазмой; процесс связан с раком эпителия протоков молочной железы, чаще внутрипротоковым, и клетки распространяются по протокам к эпидермису. Доброкачественная сосудистая опухоль соска, не связанная с эпителием, не подходит: при болезни Педжета опухоль не сосудистая и тесно связана с эпителием протоков. Представление об одном лишь воспалении кожи соска без опухолевых клеток неверно: в эпидермисе имеются опухолевые клетки, и «экзематозные» изменения нельзя считать дерматитом. Гладкомышечная опухоль с узлом в ареоле не соответствует морфологии болезни Педжета.'),
  (E'66a83541-b76d-466c-939e-4770343253e9', E'8659c06e-682f-4488-8be5-cd07cc1e5e89', E'Инвазивный рак молочной железы макроскопически может выглядеть по-разному. Чаще встречается плотный узел с неровными, нечёткими границами и белесоватыми тяжами, которые лучисто врастают в окружающую жировую ткань, что напоминает «краба»; плотность обусловлена выраженной стромальной реакцией. Возможен и диффузный вариант, при котором железа уплотнена без чётко очерченного узла, а границы плохо различимы. Состояние из одних поверхностных сосочков без вовлечения ткани железы характеризует внутрипротоковую папиллому и не соответствует инвазивному раку. Утверждение, что инвазивный рак всегда представляет собой тонкостенную кисту с прозрачной жидкостью, ошибочно: такая киста типична для доброкачественных кист. Обязательный рост на ножке в просвет характерен для опухолей полых органов, а не для молочной железы.'),
  (E'8b87f1dd-3fdc-466f-ad1d-f618c73dd4f9', E'8a13e9b5-20ce-49c8-95fa-5946f93a838d', E'Почечно-клеточный рак (аденокарцинома почки, гипернефроидный рак) — самая частая злокачественная эпителиальная опухоль почечной паренхимы у взрослых. Она развивается из эпителия проксимальных канальцев нефрона, чаще у людей 50–70 лет, и нередко прорастает в почечную вену, давая гематогенные метастазы в лёгкие, кости и головной мозг. Переходно-клеточная папиллома почечной лоханки происходит из уротелия выстилки лоханки, а не из паренхимы, и относится к доброкачественным опухолям. Плоскоклеточная папиллома кожи — доброкачественная опухоль эпидермиса и почку не поражает. Нефробластома (опухоль Вильмса) преимущественно детская, у взрослых она встречается очень редко.'),
  (E'9c6ae6e5-d81c-45cc-8ac2-0458a0a9296f', E'ccda49e9-4d60-4146-b3fb-dfc46b2171bd', E'Почечно-клеточный рак обычно выглядит как узловая опухоль в паренхиме почки, часто в полюсе органа. На разрезе она пёстрая: жёлтые участки связаны с накоплением липидов и гликогена в светлых клетках, а красные и бурые — это очаги кровоизлияний; встречаются также некрозы и кисты. Опухоль может прорастать капсулу почки и почечную вену. Множественные тонкие сосочки в мочевом пузыре без опухоли в почке типичны для уротелиальных папиллярных опухолей и не отражают рак почки. Диффузное уменьшение обеих почек без опухолевого узла говорит о хроническом склерозирующем процессе. Бородавчатая опухоль эпидермиса с ороговением относится к коже, а не к почке.'),
  (E'1c573ebb-44a4-4bc7-b6fc-9aeb6a4f1450', E'22da7892-4679-43c8-ac27-3e3dd212f66c', E'Рак почечной паренхимы и опухоли лоханки различаются гистогенезом и локализацией. Почечно-клеточный рак возникает из эпителия канальцев, лежащих в паренхиме, и встречается как светлоклеточный, папиллярный и другие варианты. Опухоли лоханки происходят из переходного эпителия — уротелия, выстилающего лоханку, чашечки и мочеточник; чаще это переходно-клеточный (уротелиальный) рак. Из-за различий в происхождении отличаются морфология, пути распространения и подходы к классификации. Утверждение о том, что обе опухоли всегда происходят из одного и того же эпителия канальцев, неверно: источники различны, поэтому строение не идентично. Мысль о том, что рак лоханки развивается только из сосудов, а рак паренхимы только из нервных клеток, ошибочна: ни эти, ни другие опухоли не происходят только из сосудов или нервных клеток. Представление о раке паренхимы как доброкачественной опухоли не подходит: он злокачественный, а опухоли лоханки чаще первичные, а не метастазы.'),
  (E'42a3b501-ed13-4510-9a94-05a88aa1ddb1', E'70c57c5d-953e-4551-8b8f-43e7fe2dd514', E'Фолликулярная аденома и фолликулярный рак щитовидной железы могут быть почти неотличимы по клеточному составу и фолликулярной архитектуре, поэтому решающим критерием служит доказанная инвазия: прорастание опухолью капсулы узла и/или проникновение в сосуды капсулы. Для этого исследуют капсулу по всей окружности на множестве срезов. Только при выявлении такой инвазии диагностируют фолликулярный рак, который метастазирует преимущественно гематогенно. Утверждение о том, что цвет коллоида позволяет надёжно определить метастазы, неверно: цвет не позволяет судить ни об инвазии, ни о метастазах. Мнение, что наличие фолликулов автоматически доказывает злокачественность, ошибочно: фолликулы есть в нормальной ткани, в доброкачественных опухолях и в зобе. Утверждение, что любая капсула вокруг узла означает рак, не подходит: капсула у аденомы типична и сама по себе не означает рак.'),
  (E'fabba7bb-224a-4377-ab7e-2d0ca3fe1c3b', E'ce62fd08-8be2-4499-b4e9-9521aef36ef7', E'Папиллярный рак — наиболее частая форма рака щитовидной железы, нередко встречающаяся у молодых и среднего возраста людей. Морфологически он образован сосочковыми структурами с тонкой соединительнотканной стромой, а его клетки имеют характерные ядра — просветлённые, с бороздками и внутриядерными включениями; нередко встречаются псаммомные тельца. Опухоль часто даёт лимфогенные метастазы в регионарные лимфатические узлы шеи, течение обычно относительно благоприятное. Представление о том, что такая опухоль развивается только у пожилых и почти немедленно разрушает ткани шеи, неверно: рак бывает не только у пожилых, а разрушение тканей шеи характерно для анапластического рака. Описание доброкачественной аденомы, не способной к инвазии, не подходит, так как это злокачественная опухоль. Опухоль из C-клеток с амилоидом как обязательным компонентом описывает медуллярный рак.'),
  (E'14b755e9-ce5c-4f6d-8e44-7119b2a06073', E'fd996ebe-9581-4424-a428-24cc6749bbf6', E'C-клетки (парафолликулярные клетки) щитовидной железы относятся к нейроэндокринной системе и вырабатывают гормон кальцитонин. Медуллярный рак развивается именно из этих клеток, поэтому повышенный уровень кальцитонина в крови служит его чувствительным опухолевым маркёром, который используют для диагностики и наблюдения после операции. Тиреоглобулин синтезируется фолликулярными клетками и служит маркёром дифференцированных опухолей из фолликулярного эпителия, а не медуллярного рака. Инсулин вырабатывают β-клетки островков поджелудочной железы. Меланин синтезируется меланоцитами и служит признаком меланоцитарных опухолей.');
INSERT INTO public.question_answers (question_id, correct_option_id, explanation) VALUES
  (E'b7d67509-86bb-429d-9f1f-7f8b4addefd0', E'85562f07-895c-48c5-9606-ae40fd1f6e58', E'Медуллярный рак щитовидной железы развивается из парафолликулярных C-клеток, секретирующих кальцитонин. Опухоль состоит из гнёзд и тяжей полигональных или веретенообразных клеток, а в строме откладывается амилоид, образующийся из продуктов белкового обмена опухолевых клеток, в частности из прокальцитонина. Окраска конго красным выявляет амилоид, а иммуногистохимия — кальцитонин. Нередко опухоль наследственная и сочетается с другими эндокринными опухолями в синдромах МЭН. Ороговевающие раковые жемчужины в тяжах плоского эпителия типичны для ороговевающего плоскоклеточного рака. Зрелые коллоидные фолликулы без атипии и инвазии характерны для нормальной ткани или зоба. Доброкачественные сосочки с сохранённой базальной мембраной и без атипии не соответствуют C-клеточной карциноме.'),
  (E'34568bac-bd25-4ee8-9261-e5333a1e4274', E'a364f3a4-e00a-4ca9-8d40-3f9ae0042859', E'Доброкачественная папиллома кожи — опухоль из плоского эпителия, которая растёт экзофитно в виде сосочка или бородавчатого образования. Паренхима образована зрелым ороговевающим плоским эпителием, строма — соединительнотканными выростами с сосудами, в нормальном порядке сохранены полярность и слоистость клеток, базальная мембрана не нарушена. Опухолевые клетки не прорастают в дерму, метастазов нет. Распространение клеток исключительно по кровеносным сосудам описывает метастазирование, которое для доброкачественной папилломы не характерно. Строма из зрелой гладкой мышцы как единственный компонент не подходит: папиллома — эпителиальная опухоль, а зрелая гладкая мышца соответствует лейомиоме. Атипичные клетки, прорастающие через базальную мембрану и образующие инвазивные тяжи, описывают инвазивный рак.'),
  (E'28cdb4a6-688c-4b7d-84a4-09aaf0c9e902', E'83f6dd31-0d33-4066-a5ec-c922c595dc49', E'Базально-клеточный рак (базалиома) — наиболее частая злокачественная опухоль кожи, происходящая из базальных клеток эпидермиса и придатков кожи. Она растёт медленно, но местно-деструирующе: прорастает дерму, подкожную клетчатку, хрящи и кости (отсюда старое название «ползучая язва»), и после неполного удаления нередко рецидивирует. В то же время метастазы практически не образуются, поэтому её относят к опухолям с местно-деструирующим ростом. Утверждение об абсолютно доброкачественной папилломе, не разрушающей окружающие ткани, неверно: базалиома не доброкачественна, а прорастает окружающие ткани. Представление об обязательных ранних множественных отдалённых метастазах ошибочно: для неё они не характерны, метастазирование крайне редко. Опухоль только из меланоцитов, содержащих меланин, не подходит: источником служат базальные клетки эпидермиса, а меланоциты дают меланому и невусы.'),
  (E'9168ff2e-aefe-44b3-b146-cedbc1d74063', E'cb64cc59-b095-48da-aeaa-3c20a050e720', E'Базалиома построена из мелких кубических или призматических клеток с гиперхромными базофильными ядрами и скудной цитоплазмой, сходных с клетками базального слоя эпидермиса. Клетки образуют гнёзда и тяжи, по периферии которых выражена палисадообразная ориентация клеток, а вокруг нередко видны щелевидные ретракции. Опухоль инвазирует дерму и может разрушать подлежащие ткани, но редко метастазирует. Правильные железистые просветы из однотипных клеток без инвазии характеризуют аденому. Крупные зрелые клетки с единственной жировой вакуолью характерны для липомы. Пласты меланоцитов с пигментом соответствуют невусу или меланоме, а наличие пигмента не определяет базалиому.'),
  (E'b2964d65-c0b9-4537-bbec-0a2aabc7132f', E'8cd1fc98-e899-4d6c-b748-0ab6ffe32f6f', E'Опухоли придатков кожи называют по тканевому происхождению. Трихоэпителиома развивается из структур волосяного фолликула или его эмбриональных элементов и образует кистозные и тяжистые структуры, напоминающие зачатки волоса. Сирингоаденома происходит из эпителия выводных протоков потовых желёз, а гидраденома — из секреторного эпителия потовых желёз и формирует железистые или кистозные структуры. Все три опухоли доброкачественные. Утверждение, что сирингоаденома и гидраденома — синонимы меланомы, неверно: меланома развивается из меланоцитов и не является синонимом опухолей потовых желёз. Соотнесение трихоэпителиомы с эндотелием сосудов, сирингоаденомы с меланоцитами и гидраденомы с гладкими мышцами ошибочно: эндотелий даёт гемангиомы, меланоциты — меланоцитарные опухоли, гладкие мышцы — лейомиомы. Мысль, что все три опухоли происходят из клеток крови и обязательно метастазируют, не подходит: опухоли придатков кожи эпителиальные и обычно не метастазируют.'),
  (E'b434c161-1fb3-4e6e-8188-44b2561d3246', E'68ce2b12-b505-4a0b-bdf8-0438f8b61073', E'Инвазивный плоскоклеточный рак кожи отличается от папилломы нарушением базальной мембраны: атипичные клетки плоского эпителия прорастают в дерму, образуют тяжи и гнёзда, нередко с признаками ороговения и раковыми жемчужинами, возможна инвазия в сосуды и метастазирование. Именно проникновение через базальную мембрану служит решающим признаком инвазивности. Отсутствие клеточной атипии и сохранение границы эпителия со стромой указывают на доброкачественный процесс, при котором инвазии нет. Зрелые потовые протоки без инвазивного компонента относятся к доброкачественным придатковым опухолям. Сосочковая поверхность при сохранённой полярности эпителия типична для самой папилломы и рак не означает.'),
  (E'a658a61b-51dc-4757-9f22-2cb61a66ce20', E'8bc882f9-dbca-4f24-a711-b7426f9fdcd2', E'Дифференцировка — степень сходства опухолевых клеток и структур с исходной тканью. Чем больше опухоль напоминает ткань, из которой она развилась, тем выше её дифференцировка и, как правило, медленнее рост и лучше прогноз. Однако хорошо дифференцированный рак всё равно остаётся злокачественным: он способен прорастать базальную мембрану, инфильтрировать ткани и метастазировать. Поэтому дифференцировку нельзя отождествлять с доброкачественностью. Утверждение о том, что высокая дифференцировка всегда означает доброкачественность и отсутствие инвазии, неверно: она не исключает инвазии, примером служит хорошо дифференцированный рак. Мысль о том, что низкая дифференцировка исключает эпителиальную природу, ошибочна: низкодифференцированные и недифференцированные опухоли могут быть эпителиальными, например плоскоклеточный рак низкой степени дифференцировки. Представление о том, что дифференцировка определяется размером узла, не подходит: размер узла не относится к критериям дифференцировки.'),
  (E'b0c60c58-9090-45ca-9189-c9f2c0f2e5b3', E'980ac96a-74d1-4dd8-a15b-bc00479651cc', E'Мезенхимальные опухоли объединяет общий источник — производные эмбриональной мезенхимы: волокнистая соединительная, жировая, гладкая и поперечнополосатая мышечная, сосудистая, костная и хрящевая ткани. Именно поэтому доброкачественные опухоли этой группы называют по ткани с суффиксом «-ома» (фиброма, липома, лейомиома, гемангиома), а злокачественные — саркомами. Тканевая принадлежность определяет строение, поведение и путь метастазирования опухоли. Утверждение о происхождении из покровного эпителия описывает эпителиальные опухоли — папилломы, аденомы и раки; эпителий не является источником мезенхимальных новообразований. Происхождение из меланоцитов свойственно меланоцитарным опухолям (невус, меланома), которые развиваются из пигментных клеток нейроэктодермального происхождения, а не из мезенхимы. Формирование из зрелых нейронов ЦНС не подходит: нейрогенные опухоли чаще возникают из глиальных и шванновских клеток и не относятся к мезенхимальным.'),
  (E'b11b1ac0-628d-4488-9770-bfb52f054c11', E'8d59d76a-0b23-4e90-8bde-5416f569b3c4', E'Доброкачественные мезенхимальные опухоли растут экспансивно: клетки раздвигают окружающие ткани, формируя узел с чёткими границами, нередко с псевдокапсулой. Клетки зрелые, близкие к нормальным, атипия минимальна, митозы единичны и типичны, поэтому метастазов опухоль не даёт и после полного удаления обычно не рецидивирует. Такой набор признаков отражает высокую степень дифференцировки и низкий пролиферативный потенциал. Инфильтрация тканей, выраженная атипия и частые патологические митозы — это перечень признаков злокачественности, характерных для сарком. Раннее гематогенное метастазирование свойственно именно злокачественным опухолям, а некроз не является обязательным признаком опухолевого роста, поэтому такой набор не годится. Прорастание сосудов говорит об инвазии, то есть о злокачественном поведении, и не зависит только от размера узла.'),
  (E'82e309e4-d659-443e-8e16-21b05a6fbc4f', E'aaf2f5cb-f6af-48d4-99ef-5b003a681e82', E'Для злокачественной мезенхимальной опухоли — саркомы — типичен инфильтративный рост: опухолевые клетки прорастают окружающие ткани, не имеют истинной капсулы и проникают в сосуды. Они дают рецидивы после удаления и способны метастазировать, чаще гематогенно, в первую очередь в лёгкие. Клетки саркомы атипичны, с повышенной митотической активностью, часто с патологическими митозами. Эти признаки отличают её от доброкачественных аналогов. Медленный рост с чёткой капсулой без инвазии описывает доброкачественную опухоль, например фиброму или липому. Полное сходство клеток с нормальной тканью и отсутствие митозов указывают на зрелую доброкачественную опухоль и противоречат самому понятию злокачественности. Ограничение локализации одной лишь кожей неверно, поскольку саркомы возникают в любой мезенхимальной ткани — в мягких тканях, костях, внутренних органах.'),
  (E'f92de2c3-5c00-43f7-8d9f-bbc704bd44f0', E'c34afdca-4b4b-42a2-8373-3a72e59841f8', E'Гемосидерин — железосодержащий пигмент, возникающий при распаде гемоглобина и накапливающийся, в частности, в макрофагах. Билирубин относится к желчным пигментам, липофусцин образуется из остаточных продуктов окисления, а меланин синтезируется меланоцитами. При окраске гемосидерин выглядит как зернистый золотисто-коричневый пигмент, а гистохимическая реакция Перлса позволяет подтвердить наличие железа. Он отличается от ферритина большей агрегированностью и обычно становится заметным при значительном накоплении железа в клетках.'),
  (E'a6376c05-9f9c-49ce-bcca-24bb61b6aa5a', E'f5c190de-6fac-45f3-a893-5c83a5b08a1e', E'Фиброма — доброкачественная опухоль из зрелой волокнистой соединительной ткани. Она состоит из пучков коллагеновых волокон и фибробластоподобных клеток, лежащих между ними; соотношение клеточного и волокнистого компонентов определяет плотность узла. Клетки зрелые, без атипии, рост медленный, экспансивный, метастазы отсутствуют. Кровенаполненные сосудистые полости составляют основу гемангиомы, а не фибромы, где нет коллагена и фибробластов в таком качестве. Атипичные меланоциты с инвазивным ростом характеризуют меланому — злокачественную опухоль меланоцитов; фиброма из пигментных клеток не развивается и инвазивно не растёт. Пучки гладкомышечных клеток как единственный компонент относятся к лейомиоме, а в фиброме гладкая мышца не является ни основным, ни единственным элементом.'),
  (E'8028d285-5e77-4bb2-b464-b71508d32197', E'cdc20cde-49e2-440e-b17f-9f35b222cbc9', E'Плотная фиброма (твёрдая) построена преимущественно из толстых, плотно лежащих пучков зрелых коллагеновых волокон, между которыми находится сравнительно небольшое число вытянутых фиброцитов и фибробластов. Из-за обилия коллагена узел на разрезе белесоватый, волокнистый, плотной консистенции, а клеточный компонент и сосудистая сеть выражены слабо. Именно соотношение «много волокон — мало клеток» отличает этот вариант от мягкой фибромы. Расширенные сосудистые лакуны свидетельствуют о сосудистой опухоли — кавернозной гемангиоме, а не о фиброзной. Пласты атипичных меланоцитов с многочисленными митозами характерны для меланомы и не встречаются в доброкачественной зрелой фиброме. Дольки зрелых адипоцитов с тонкими перегородками составляют строение липомы.'),
  (E'49204c65-3d61-4be8-b16d-7aeacfbe0f82', E'61cdc51a-e6dd-4ea3-a798-d884cfc30d3d', E'Мягкая фиброма отличается от плотной количественным соотношением компонентов: в ней больше клеток (фибробластов), строма рыхлая, отёчная, с тонкими разрозненными коллагеновыми волокнами и хорошо развитыми сосудами, тогда как плотных толстых пучков коллагена меньше. В результате мягкая фиброма имеет более мягкую консистенцию. Обе разновидности остаются доброкачественными и построены из волокнистой соединительной ткани. Обязательные метастазы не характерны ни для мягкой, ни для плотной фибромы, так как обе доброкачественны. Полное отсутствие соединительнотканного компонента исключено: он составляет основу любой фибромы, и без него опухоль нельзя так назвать. Меланоцитарное происхождение свойственно невусам и меланомам, тогда как фиброма развивается из фибробластов.'),
  (E'814c8f2f-d794-4add-aef1-3e8121e9b61f', E'9566cf5a-96b7-4843-8566-65fe94306c34', E'Лейомиома — доброкачественная опухоль гладкой мышечной ткани. Под микроскопом она состоит из переплетающихся пучков зрелых веретеновидных гладкомышечных клеток с палочковидными ядрами, расположенных в разных направлениях; клеточная атипия и патологические митозы отсутствуют, митозы редки. Макроскопически это чётко отграниченный плотный узел серовато-белого цвета с «вихревидным» рисунком на разрезе. Сосудистые каналы, выстланные эндотелием, характерны для гемангиом, а не для гладкомышечных новообразований. Зрелые адипоциты, разделённые тонкими перегородками, составляют строение липомы. Гнёзда невусных клеток в эпидермисе типичны для меланоцитарного невуса, у которого они лежат в эпидермисе или на границе эпидермиса и дермы.'),
  (E'686b5114-4d43-4167-b993-9a13ffacde47', E'34d4e645-1169-4bf2-ada5-471189b413f4', E'Лейомиома матки — самая частая доброкачественная опухоль женских половых органов. Она растёт из миометрия в виде одного или нескольких узлов — под слизистой оболочкой, в мышечной стенке или под серозной оболочкой. Симптомы зависят от размера и расположения узлов: могут быть меноррагии и маточные кровотечения, боль, нарушения репродуктивной функции, а крупные узлы сдавливают мочевой пузырь и прямую кишку. Обязательное метастазирование в лёгкие лейомиоме не свойственно: она доброкачественна, а такие метастазы возможны лишь при лейомиосаркоме. Диффузное замещение миометрия меланоцитами не соответствует гистогенезу — миометрий состоит из гладких мышц и меланоцитарной трансформации не претерпевает. Синюшные сосудистые полости без мышечной ткани характерны для сосудистых опухолей, тогда как лейомиома образована именно гладкомышечной тканью.'),
  (E'f2d7a41e-4b03-4365-a83c-2989dd487039', E'178a3e58-fc61-44a4-9383-206b1b5f38ec', E'Лейомиому от лейомиосаркомы отличают по комплексу морфологических критериев: степени клеточного атипизма и полиморфизма, числу митозов на единицу площади, в том числе атипичных, наличию опухолевого коагуляционного некроза и инвазивному росту в окружающие ткани. Ни один признак по отдельности не является абсолютным, поэтому диагноз ставят, оценивая их совокупность. Это определяет прогноз и тактику лечения. Один лишь диаметр узла не доказывает злокачественности: крупные лейомиомы бывают доброкачественными. Сам по себе факт наличия гладкомышечных клеток ничего не разграничивает, так как они есть и в доброкачественной, и в злокачественной опухоли. Цвет на разрезе — неспецифический внешний признак, не позволяющий судить о биологии опухоли.'),
  (E'989881d1-adf1-4fe4-a170-012d65c863c6', E'f4ca18a2-ecf6-4542-a60a-17f2315c48a1', E'Доброкачественная опухоль из поперечнополосатой мышечной ткани называется рабдомиомой. Её клетки сохраняют признаки скелетной или сердечной мышечной дифференцировки, в том числе поперечную исчерченность. Рабдомиому сердца у детей нередко связывают с туберозным склерозом. Злокачественным аналогом является рабдомиосаркома. Лейомиома развивается из гладкой, а не из поперечнополосатой мышцы. Фиброма — доброкачественная опухоль волокнистой соединительной ткани, не имеющая мышечной дифференцировки. Гемангиома — опухоль из сосудистых структур, формируемая эндотелиально выстланными каналами.'),
  (E'65d0e037-387d-49d6-83aa-d9492c052ad7', E'ce74b46d-57bc-4f60-aef6-28b3b0ed1804', E'Для многих сарком типично гематогенное метастазирование: опухолевые клетки проникают в венозные сосуды и с током крови достигают органов-мишеней, прежде всего лёгких, а также печени, костей и головного мозга. Лимфогенные метастазы в регионарные лимфатические узлы у сарком возникают реже, чем у раков. Поэтому при обследовании больных саркомами обязателен контроль лёгких. Пути распространения зависят от типа опухоли, но гематогенный путь — ведущий. Лимфогенный путь не является единственным и основным для сарком, а отдалённые метастазы встречаются часто. Исключительно контактное распространение невозможно: помимо местной инвазии, саркомы проникают в сосуды и дают отдалённые метастазы. Метастазирование лишь после хирургического удаления — ошибка: метастазы возникают вследствие биологических свойств опухоли, а не операции, и могут быть обнаружены ещё до лечения.'),
  (E'e99ddb32-5886-46ab-a7d2-2b3940692f17', E'004204c5-a3d8-4c39-a106-2e6f1517b2ea', E'Гемангиома — доброкачественная опухоль сосудистого происхождения. Она состоит из сосудистых каналов или полостей, выстланных одним слоем эндотелия и заполненных кровью, между которыми расположена соединительнотканная строма. По строению различают капиллярные, кавернозные и другие формы. Опухоль растёт медленно, не метастазирует, но может кровоточить и сдавливать соседние структуры. Зрелые гладкомышечные пучки без просветов составляют основу лейомиомы, а не сосудистой опухоли. Гнёзда меланоцитов характерны для меланоцитарного невуса. Коллагеновые пучки без сосудистого компонента описывают фиброму; без сосудов диагноз гемангиомы невозможен.'),
  (E'4e6f74cb-dc50-4879-be49-5b890a9ec966', E'4c2da218-486f-4bf1-baa1-379c4e68015c', E'Капиллярная гемангиома построена из множества мелких сосудов капиллярного типа, выстланных эндотелием, с небольшими просветами; чаще располагается в коже и подкожной клетчатке. Кавернозная гемангиома состоит из крупных, резко расширенных тонкостенных кровенаполненных полостей — каверн, разделённых соединительнотканными перегородками, встречается в коже, печени, головном мозге. Различие определяется калибром сосудистых пространств. Утверждение о злокачественности капиллярной формы и обязательном метастазировании кавернозной неверно: обе гемангиомы доброкачественны. Происхождение из меланоцитов и нейронов бессмысленно с точки зрения гистогенеза — эти опухоли состоят из эндотелия и сосудов. Мнение, что обе состоят только из коллагена, ошибочно: основа гемангиом — сосудистые структуры, а коллаген лишь образует стромальную прослойку.'),
  (E'f4779588-681d-4830-b8ef-07c9de1b6acc', E'bf531de5-87e9-496e-802d-bb4f34b5a1ef', E'Регенерация — восстановление утраченных или повреждённых структур за счёт клеточного размножения и/или обновления внутриклеточных компонентов. Уменьшение ткани относится к атрофии; замещение дефекта соединительной тканью — к субституции, а не к восстановлению исходной паренхимы; увеличение органа под нагрузкой соответствует гипертрофии. Поэтому определяющим признаком регенерации является восстановление структуры, а не просто изменение объёма.'),
  (E'397c9c0f-e8e1-416e-ab54-b98850386100', E'5bbbf4b7-3029-43e8-923d-3d53c4603892', E'Значение сосудистого образования определяется не только его гистологией, но и локализацией и размером. В функционально важной области, например в глотке, гортани, орбите или головном мозге, даже доброкачественная гемангиома может кровоточить, изъязвляться, инфицироваться и сдавливать соседние органы, нарушая дыхание, зрение или глотание. Поэтому такие образования требуют наблюдения и при необходимости лечения. Неизбежное превращение в меланому исключено: гемангиомы — сосудистые опухоли, имеющие иной гистогенез. Обязательное формирование костной ткани для сосудистых образований не характерно. Полное отсутствие клинических последствий при любом размере тоже неверно: последствия зависят от локализации, и крупные или расположенные в жизненно важных зонах образования могут нарушать функцию.'),
  (E'1cd6dc23-d087-4b21-a78d-d65341528d28', E'03349c30-92e1-435a-a353-fb020fc51ad5', E'Меланоцитарную природу невуса определяют невусные клетки — изменённые меланоцитарные клетки, происходящие из нейроэктодермы (нервного гребня). Они образуют гнёзда и тяжи: на границе эпидермиса и дермы (пограничный невус), в дерме (внутридермальный невус) или в обоих отделах (сложный невус). В клетках обычно есть меланин, они однотипны, без атипии. Эти признаки отличают невус от опухолей других тканей. Эндотелиальные клетки сосудов формируют просветы сосудов, а не гнёзда невусных клеток, поэтому они относятся к сосудистым образованиям. Фибробласты с массивным синтезом коллагена составляют основу фибромы и меланин не образуют. Гладкомышечные клетки, формирующие пучки, характеризуют лейомиому.'),
  (E'9c8314f8-e973-4231-ab51-b98a7db4bd20', E'fa5152a5-f4fa-4b86-88cd-881d29c99c4f', E'Клинически на меланому указывают признаки, объединённые правилом ABCDE: асимметрия образования, неровные границы, неоднородная окраска (разные оттенки коричневого, чёрного, красного), диаметр более 6 мм и динамика — изменение размера, цвета, формы, появление кровоточивости или зуда. Эти признаки отражают неравномерный, инвазивный рост атипичных меланоцитов и требуют срочного осмотра и гистологического исследования. Симметрия и стабильная равномерная окраска — признаки, более свойственные доброкачественному невусу. Отсутствие изменений при длительном наблюдении нельзя считать единственным критерием, так как диагноз опирается на комплексную клиническую и морфологическую оценку. Расположение исключительно в подкожной клетчатке неверно: меланома развивается в коже, слизистых оболочках, сетчатке и других местах, где есть меланоциты.'),
  (E'df98d849-91fe-4d61-9d75-1d8330e09db1', E'28abf36f-7683-4d9c-82a0-e65961de8333', E'Морфологически меланому диагностируют по атипичной пролиферации меланоцитов: клетки полиморфны, с крупными ядрами, заметными ядрышками, патологическими митозами, нарушено их созревание и расположение в эпидермисе и дерме, выявляются инвазия в глубину и пагетоидное распространение в эпидермисе. Для подтверждения применяют иммуногистохимию (S-100, HMB-45, Melan-A). Эти признаки отличают меланому от невуса. Один лишь коричневый цвет не заменяет гистологию: меланома бывает беспигментной, а пигментные доброкачественные образования встречаются часто. Плотный коллагеновый матрикс без меланоцитов соответствует фиброзной опухоли и не отражает меланоцитарной природы. Однородные сосудистые каналы без атипии характерны для гемангиомы.'),
  (E'5f5abeb2-ff10-4cb9-85b5-97b8e23a0277', E'1aafa934-62a9-4d40-b21f-6058c0aa92d2', E'Вертикальная фаза роста меланомы означает, что опухолевые клетки проникают за пределы эпидермиса и распространяются вглубь — в сосочковый и ретикулярный слои дермы и подлежащие ткани. Клетки формируют узел, приобретают инвазивные свойства, опухоль получает доступ к лимфатическим и кровеносным сосудам, резко возрастает риск метастазов. Именно с этой фазой связано ухудшение прогноза, в отличие от радиальной фазы. Распространение только по поверхности эпидермиса без инвазии описывает радиальную фазу, при которой клетки растут внутри эпидермиса и поверхностного слоя дермы без выраженной глубинной инвазии. Полное восстановление нормального эпидермиса не имеет отношения к росту опухоли: меланома к такому исходу не приводит. Формирование сосудистых полостей характерно для гемангиом и не определяет фазу роста меланомы.'),
  (E'bde8fdde-55a2-4436-85dc-d00d902b490f', E'd451e44e-435b-4b33-a4cf-45d717cffd63', E'Толщина по Бреслоу — вертикальный размер меланомы, измеряемый микрометром от зернистого слоя эпидермиса (или дна изъязвления) до самой глубокой опухолевой клетки. Это важнейший морфологический прогностический показатель: чем больше толщина, тем выше риск метастазов в лимфатические узлы и отдалённые органы и тем хуже выживаемость. Показатель определяет объём иссечения и необходимость биопсии сторожевого лимфатического узла. Площадь окрашенного участка не отражает глубину инвазии и индексом Бреслоу не является. Число сосудов этим показателем не измеряется и его значение не определяет. Различать фиброму и липому по Бреслоу нельзя: эти опухоли отличаются клеточным составом и строением, а показатель применяют только при меланоме.'),
  (E'40a83285-fd3a-4c52-877f-0ad9c3dcbd4f', E'056ac44d-5406-4cd7-97e0-4523e695126e', E'Невус — доброкачественное скопление невусных клеток, обычно стабильное, симметричное, с равномерной окраской и без атипии. Меланома — злокачественная опухоль из меланоцитов с клеточной атипией, нарушением созревания, инвазивным ростом и способностью к лимфогенному и гематогенному метастазированию. Меланома может возникнуть на фоне невуса или на неизменённой коже. Именно оценка потенциала инвазии отличает эти процессы. Представление о том, что любой невус превращается в меланому, ошибочно: подавляющее большинство невусов никогда не малигнизируется, хотя риск повышается при диспластических невусах. Утверждение о всегда беспигментной меланоме тоже неверно: она нередко пигментирована, но существуют и беспигментные (амеланотические) формы, поэтому слово «всегда» некорректно. Различие только по диаметру недостаточно: дифференциальный диагноз основан на клеточной атипии, митозах и инвазии, а размер служит лишь клиническим ориентиром.'),
  (E'd8778e9f-15d9-48d8-b931-cffcd06a282c', E'7e5639ba-82d8-4f5c-b15b-9f0a2827e18d', E'Шваннома (неврилеммома) — доброкачественная опухоль, развивающаяся из шванновских клеток, образующих миелиновую оболочку периферических нервов. Она растёт медленно в виде инкапсулированного узла, прилежащего к нерву и оттесняющего его волокна; часто поражает чувствительные корешки и вестибулярный нерв (невринома слухового нерва). Опухоль гистологически характерна и подтверждается положительной реакцией на белок S-100. Лейомиома развивается из гладкой мышечной ткани, а не из шванновских клеток. Гемангиома происходит из эндотелиальных и сосудистых структур. Липома — опухоль жировой ткани, а не нервной оболочки.'),
  (E'6155bde6-37e8-4f96-86f6-ede3c3f3b14d', E'58c9a3b5-4099-487b-9d0b-fc2fc2271db2', E'Классическая шваннома имеет двухкомпонентное строение. Участки Антони A — плотные, клеточные, из веретеновидных клеток, образующих палисадные структуры, в которых ядра выстраиваются рядами вокруг безъядерных зон, формируя тельца Верокаи. Участки Антони B — рыхлые, гипоклеточные, с микрокистами, отёком и сосудами с гиалинизированными стенками. Сочетание этих зон и телец Верокаи считается типичным морфологическим признаком опухоли. Одни лишь зрелые адипоциты составляют строение липомы: в шванноме жировые клетки не являются основным компонентом. Гнёзда меланоцитов с эпидермальным распространением характеризуют невус и меланому, а не опухоль нервной оболочки. Крупные сосудистые полости без клеточных компонентов описывают гемангиому и не соответствуют шванноме, у которой есть клеточные зоны Антони A.'),
  (E'8711bf53-d2f2-4a5e-b557-656ca7dda594', E'26bb31d9-37b7-47b9-b20b-26a46df1c78c', E'Нейрофиброма — доброкачественная опухоль периферического нерва со смешанным клеточным составом: шванновские клетки, фибробласты, периневральные клетки и тучные клетки среди коллагеновых волокон и слизистой стромы. Она растёт диффузно и, в отличие от шванномы, не имеет чёткой капсулы, а нервные волокна проходят через опухоль, а не оттесняются ею. Это различие важно для хирургии, так как удалить нейрофиброму, не повредив нерв, труднее. Состав только из эндотелия характерен для сосудистых опухолей, тогда как нейрофиброма строится из клеток оболочки нерва. Утверждение о постоянной злокачественности неверно: нейрофиброма обычно доброкачественна, хотя при нейрофиброматозе 1 типа возможна малигнизация. Состав исключительно из зрелых жировых клеток описывает липому и не соответствует гистогенезу нейрофибромы.'),
  (E'b31f562b-154c-4fd2-a7f0-41a8f52fa4e0', E'9eec6da4-893c-40fc-ab68-502d660df153', E'Множественные нейрофибромы — основной признак нейрофиброматоза 1 типа (болезни Реклингхаузена): аутосомно-доминантного заболевания, вызванного мутацией гена NF1, кодирующего белок нейрофибромин, подавляющий передачу сигнала RAS. Кроме нейрофибром, наблюдаются пятна цвета «кофе с молоком», узелки Лиша на радужке, глиомы зрительного нерва, веснушчатость в подмышечных областях. Повышен риск злокачественных опухолей оболочек нервов. Изолированный обычный невус не связан с этим синдромом и не объясняет множественные поражения нервов. Лейомиома матки — гладкомышечная опухоль, не имеющая отношения к нейрофиброматозу. Капиллярная гемангиома — сосудистая опухоль и причиной нейрофибром не является.'),
  (E'11f43a61-8335-446c-8c00-4af7ad736d77', E'c6a013c9-d685-4cc4-8e6a-52ad39714113', E'О злокачественной опухоли периферической нервной оболочки (злокачественной шванноме) свидетельствуют инфильтративный рост с проникновением в окружающие ткани, выраженная атипия клеток, высокая митотическая активность, в том числе атипичные митозы, и участки некроза. Такие опухоли чаще развиваются на фоне нейрофиброматоза 1 типа или в зоне облучения, склонны к рецидивам и гематогенным метастазам. Чёткая отграниченность и отсутствие митозов описывают доброкачественную опухоль, например шванному. Зрелые адипоциты без атипии указывают на липому, а не на нервно-оболочечную саркому. Коллагеновые волокна без опухолевой клеточной пролиферации вовсе не говорят об опухоли: это признак рубцовой или фиброзной ткани.'),
  (E'4f761bfc-f12c-43a9-85ad-218c40197494', E'81121cd7-68a5-494a-8b48-e5be5018d8f0', E'Опухоли периферических нервов вызывают парестезии из-за механического воздействия на нервные волокна. Растущий узел сдавливает или растягивает нерв, раздражает аксоны и нарушает кровоснабжение, поэтому возникают покалывание, онемение, боль, иррадиирующая по ходу нерва, а позже — слабость и нарушения чувствительности. Выраженность симптомов зависит от размера и расположения опухоли. Синтез меланина свойствен меланоцитам и не является механизмом симптомов при нервных опухолях. Гемолиз — это разрушение эритроцитов, и с опухолями нервов он не связан. Эпителиальная метаплазия представляет собой перестройку эпителия и к нервным волокнам отношения не имеет.'),
  (E'a228eb13-9893-4294-a17c-0b24cb7af796', E'adf7dc91-479f-4992-af47-0015d683a162', E'Сосудистые образования у детей неоднородны. Инфантильные гемангиомы — истинные доброкачественные опухоли: появляются в первые недели жизни, быстро растут в фазе пролиферации, затем медленно инволюционируют, оставляя иногда фиброзно-жировые изменения. Сосудистые мальформации, напротив, представляют собой пороки развития сосудов, не регрессируют и растут вместе с ребёнком. Поэтому тактику определяют по типу и локализации образования. Мнение, что все такие образования — саркомы, неверно: большинство детских сосудистых образований доброкачественны, а саркомы среди них редки. Обязательная регрессия без наблюдения тоже ошибочна: она характерна не для всех образований, а мальформации самостоятельно не исчезают. Утверждение, что они никогда не нарушают функцию органов, неверно: образования в области глаза, дыхательных путей или внутренних органов могут нарушать функции.'),
  (E'4a109bcc-2b98-4bb3-9cb1-3db07493b227', E'088f738b-ccea-420b-be6a-bee97fbd704c', E'Инфантильная гемангиома обычно становится заметной в первые недели жизни как красное пятно или узелок, затем в течение нескольких месяцев быстро растёт (фаза пролиферации), после чего наступает стабилизация и медленная инволюция, порой в течение нескольких лет. Эта последовательность отличает её от врождённых сосудистых мальформаций, которые существуют с рождения и не регрессируют. Гистологически она состоит из пролиферирующих эндотелиальных клеток, формирующих капилляры. Мысль о том, что образование полностью сформировано при зачатии и не меняется, неверна: оно появляется после рождения и динамично меняется. Отождествление с меланомой у младенцев ошибочно, так как меланома и гемангиома — разные опухоли из разных тканей. Состав исключительно из гладкомышечных пучков описывает лейомиому, тогда как гемангиома построена из сосудистых структур.'),
  (E'e15608a9-1d5c-4b1c-bcf3-8d75f290fb40', E'e4516fe1-4f36-42e1-99e4-18c6a1172dc1', E'Гемангиомы вблизи дыхательных путей, глаза или рта требуют особого внимания, потому что значение сосудистой опухоли определяется не только её доброкачественностью, но и локализацией. В области гортани и трахеи опухоль может сузить просвет и вызвать стридор и удушье, а вблизи глаза — сдавить глазное яблоко, вызвать астигматизм, амблиопию и потерю зрения у ребёнка. Поэтому показано раннее наблюдение и при необходимости лечение. Утверждение, что такая локализация сама по себе доказывает метастазирование, неверно: расположение гемангиомы метастазов не подтверждает, а сама опухоль доброкачественна. Мнение, что доброкачественные образования не могут нарушать функции органов, ошибочно: доброкачественность не исключает функциональных нарушений при сдавлении важных структур. Превращение в фиброму как единственное осложнение невозможно: гемангиома в фиброму не превращается, а её осложнения связаны с кровотечением, изъязвлением и сдавлением.'),
  (E'c880d40b-d44f-4f5f-aca6-fd771cd995f1', E'bcfe58d2-258d-4f1e-9210-6d003418e6bf', E'Нефробластома (опухоль Вильмса) — злокачественная эмбриональная опухоль почки, развивающаяся из метанефрогенной бластемы, то есть незрелой нефрогенной ткани. Встречается преимущественно у детей до 5 лет, проявляется пальпируемым образованием в животе, гематурией и артериальной гипертензией. Метастазирует чаще гематогенно в лёгкие, при своевременном лечении имеет относительно благоприятный прогноз. Связана с мутациями гена WT1. Доброкачественная опухоль сосудов кожи — это гемангиома, тогда как нефробластома локализована в почке и злокачественна. Меланоцитарная опухоль сетчатки не подходит: опухоль сетчатки называется ретинобластомой и имеет другой гистогенез. Доброкачественная опухоль шванновских клеток — шваннома, это опухоль оболочек нервов, не связанная с почкой.'),
  (E'56252a19-62ac-41cf-9319-c897c75669db', E'6a0cf6ec-0ddf-457f-a072-529981fd2934', E'Классическая нефробластома имеет трёхкомпонентное (трифазное) строение: бластемный компонент — плотные скопления мелких недифференцированных округлых клеток; эпителиальный — клетки, образующие примитивные канальцы и клубочкоподобные структуры; стромальный — веретеновидные клетки, иногда с мышечной, жировой или хрящевой дифференцировкой. Соотношение компонентов варьирует, а их сочетание отражает происхождение опухоли из метанефрогенной бластемы. Только зрелые адипоциты не определяют строение нефробластомы: жировые клетки могут встречаться лишь как редкий элемент стромы. Одни меланоциты в её составе не встречаются, так как опухоль не является меланоцитарной. Одни кровенаполненные сосудистые полости характерны для гемангиом, а в нефробластоме сосуды составляют лишь часть стромы.'),
  (E'701d2ce3-0504-476f-8197-fdb6280f5968', E'599eef8b-b1cf-4fe8-a09c-5d580ef13835', E'Ретинобластома — злокачественная эмбриональная опухоль сетчатки, развивающаяся из незрелых нейроэктодермальных клеток сетчатки. Встречается преимущественно в раннем детском возрасте, обычно до 5 лет, и бывает наследственной или спорадической. Она состоит из мелких базофильных клеток с крупными гиперхромными ядрами, образующих розетки Флекснера — Винтерштейнера, часто с участками некроза и кальцификатов. Опухоль может прорастать в зрительный нерв и метастазировать. Доброкачественная опухоль гладкой мышцы — это лейомиома, она не связана с сетчаткой и не является эмбриональной. Сосудистая мальформация кожи представляет собой порок развития сосудов, а не опухоль сетчатки. Опухоль периферического нерва взрослого возникает из оболочек нервов, а ретинобластома развивается из сетчатки у детей.'),
  (E'a88601be-c8bd-4edf-bd5e-96984e89ffba', E'37fe0d23-f928-4e44-a4d6-df0152c6e2c9', E'Характерным признаком ретинобластомы является лейкокория — белое свечение зрачка при освещении («симптом кошачьего глаза»), обусловленное опухолевой массой в стекловидном теле. Нередко возникает косоглазие из-за снижения зрения, затем могут появиться боль, покраснение и увеличение глаза. При выявлении лейкокории у ребёнка показан срочный осмотр офтальмолога. Синюшная бляшка на коже туловища указывает на сосудистую опухоль кожи, а не на поражение глаза. Маточные кровотечения относятся к гинекологической патологии, например к лейомиоме матки, и не связаны с детской опухолью глаза. Пигментная полоска ногтя как единственный симптом вызывает подозрение на подногтевую меланому, но не является типичным проявлением ретинобластомы.'),
  (E'c5443a93-0151-402b-93a0-04bcf1c8d39a', E'dba0ddc4-d1a5-476b-8257-8e8bd4655d3d', E'При наследственной ретинобластоме мутация гена-супрессора RB1 присутствует во всех клетках организма (зародышевая линия), поэтому достаточно одной дополнительной мутации в сетчатке, чтобы возникла опухоль. Согласно гипотезе Кнудсона, это объясняет раннее начало, множественные очаги и высокую частоту двусторонних поражений, а также повышенный риск вторых опухолей, например остеосарком. Ненаследственная форма обычно односторонняя и одиночная. Утверждение об обязательной односторонности и отсутствии связи с генами неверно: наследственная форма часто двусторонняя и генетически обусловлена. Возникновение исключительно после травмы глаза тоже ошибочно: травма причиной опухоли не является, а наследственная форма определяется мутацией RB1. Отнесение к гемангиомам неверно, поскольку гемангиома — сосудистая опухоль, а ретинобластома — эмбриональная опухоль сетчатки.'),
  (E'24286ab1-1728-49b7-b682-8ceea1036fd7', E'62f17c54-d11f-461e-9dcf-27158a5952f1', E'У детей большую роль играют эмбриональные опухоли, возникающие из незрелых тканевых зачатков в результате нарушения нормального развития органов, например нефробластома, ретинобластома, нейробластома, рабдомиосаркома. Их клетки напоминают клетки эмбриональных тканей и сочетают высокую пролиферативную активность с потенциалом дифференцировки. Возраст ребёнка влияет на спектр возможных опухолей и подход к диагностике, а не только на гистогенез. Представление о доброкачественности всех детских мезенхимальных опухолей ошибочно: среди них есть как доброкачественные (гемангиомы), так и злокачественные эмбриональные саркомы. Происхождение только из зрелой соединительной ткани не подходит: детские опухоли часто возникают из незрелых мезенхимальных клеток-предшественников. Мысль о том, что возраст не влияет на спектр опухолей, неверна: он существенно зависит от возраста — у детей преобладают эмбриональные опухоли, а у взрослых раки.'),
  (E'eab7dd26-4b0d-447f-b2a6-3f84c2017604', E'973154a3-6eb5-4416-b685-e5faeb0b687a', E'Гистогенез опухоли — её тканевое происхождение — устанавливают по морфологии: строению клеток, их сходству с определённой тканью, характеру волокон, секреторным и другим продуктам и общей архитектуре опухоли. Если картина неясна, особенно при малодифференцированных опухолях, применяют иммуногистохимию: выявление маркеров (например, виментина, десмина, S-100, цитокератинов) позволяет определить линию дифференцировки. Только такой комплексный подход обосновывает диагноз. Цвет образования — внешний признак, не отражающий тканевую принадлежность клеток. Возраст пациента помогает определить вероятные диагнозы, но не заменяет микроскопическое исследование. Боль — неспецифический симптом, который может сопровождать самые разные процессы.'),
  (E'6f827ef9-c081-4468-94ce-1986affa5c7c', E'c8f2ecdc-3982-4e11-9c71-e6df97813214', E'Для сарком типично гематогенное метастазирование: клетки проникают в тонкостенные вены, разносятся с током крови и оседают в органах первого капиллярного барьера, прежде всего в лёгких, а также в печени, костях и головном мозге. Лимфогенные метастазы встречаются реже и характерны для отдельных вариантов. Знание этой закономерности определяет схему обследования: оценку лёгких проводят во всех случаях. Исключительно лимфогенный путь не годится: он преобладает у раков, а не у сарком. Только контактное распространение — это местный рост, а не метастазирование, и оно не исчерпывает пути распространения сарком. Утверждение, что метастазы возникают только после операции, ошибочно: они обусловлены биологическими свойствами опухоли и нередко присутствуют ещё до вмешательства.'),
  (E'27b610f6-dc90-4721-83f5-d6c6cb2d8762', E'9119120c-1397-4ab3-8665-761ead480679', E'Смешанные дистрофии проявляются нарушениями обмена сложных веществ как в паренхиме, так и в строме или межклеточном веществе. Изменения, ограниченные клетками паренхимы, относятся к паренхиматозным дистрофиям, а преимущественно затрагивающие внеклеточный матрикс — к стромально-сосудистым; нарушение только минерального обмена само по себе не определяет смешанную дистрофию. Для смешанных дистрофий важен не один изолированный участок, а сочетание изменений в клетках и тканевых структурах; к ним относят нарушения обмена сложных белков, липопротеидов и минеральных соединений. Изменения только в паренхиме соответствуют паренхиматозным дистрофиям, а преимущественно во внеклеточном матриксе — стромально-сосудистым.'),
  (E'64faf5c2-3b2b-42c8-b4f3-7937dfcd77ba', E'cd18c186-c97e-4684-9c5e-6d6d10b3f92c', E'Название опухоли отражает ткань, из которой она растёт: липома развивается из жировой ткани, фиброма — из волокнистой соединительной ткани, лейомиома — из гладкой мышцы. Все три — доброкачественные опухоли, построенные из зрелых клеток соответствующей ткани. Такое соответствие лежит в основе номенклатуры мезенхимальных опухолей. Сочетание, где липома происходит из эндотелия, фиброма состоит из меланоцитов, а лейомиома развивается из нервных клеток, неверно по всем трём пунктам. В сочетании с гемангиомой из адипоцитов, шванномой из гладкой мышцы и невусом из коллагена всё перепутано: гемангиома происходит из сосудов, шваннома — из шванновских клеток, невус — из меланоцитарных клеток. В сочетании, где меланома растёт из эндотелия, нефробластома из эпидермиса, а ретинобластома из хряща, источники указаны неверно: меланома развивается из меланоцитов, нефробластома — из почечной бластемы, ретинобластома — из сетчатки.'),
  (E'54f28afd-dc83-415a-8d01-d6455056c0d2', E'8d8f5f3a-c536-4933-81ba-845827eff8e8', E'Макроскопически невус и меланома могут быть очень похожи, поэтому надёжно различить их можно только при морфологическом исследовании. Патолог оценивает клеточную атипию, митотическую активность, симметрию и архитектуру образования, зрелость клеток по мере углубления в дерму, а также инвазию, определяя толщину по Бреслоу и уровень инвазии по Кларку. Клинические признаки лишь указывают на необходимость биопсии. Утверждение, что меланома всегда бесцветна и не видна клинически, неверно: она бывает пигментированной и видна клинически, а беспигментные формы лишь осложняют диагностику. Мысль о том, что невусы не содержат меланоцитов, ошибочна: они состоят из невусных клеток меланоцитарного происхождения. Одинаковое строение всех пигментных образований не соответствует действительности: они различаются по строению, поэтому внешнего сходства недостаточно.'),
  (E'b5e707a0-11ce-41e2-b8aa-fc1665ad652e', E'6c4f1113-fec4-40c7-b9ce-cf82119dbc26', E'При классификации опухолей учитывают гистогенез — ткань происхождения, морфологию — строение и клеточный состав, степень дифференцировки, то есть сходство со зрелой тканью, и биологическое поведение — характер роста, склонность к рецидивам и метастазам. Такая основа лежит в современной классификации ВОЗ и позволяет оценить прогноз и выбрать лечение. Эти критерии объединяют морфологические и клинико-биологические особенности опухоли. Цвет и диаметр — внешние признаки, не определяющие природу опухоли. Локализация без микроскопии не позволяет установить гистогенез и степень злокачественности. Боль — неспецифический симптом, а не классификационный критерий.'),
  (E'46245047-3ce2-42e3-b24b-e1094809770c', E'39c6ea80-495b-4b3b-9e81-20e5dd9848e2', E'Иммуногистохимию при опухолях меланоцитарной и нервной дифференцировки применяют как панель маркеров. Например, S-100, SOX10, HMB-45 и Melan-A выявляют меланоцитарную дифференцировку, а S-100 и SOX10 — шванновскую, причём специфичность отдельных маркеров ограничена. Результат интерпретируют вместе с морфологией и клиническими данными, так как только совокупность сведений позволяет поставить точный диагноз. Один маркер не всегда специфичен, и вывод только по нему может привести к ошибке. Измерение диаметра опухоли не входит в задачи метода: он выявляет белки в клетках. Цвет ткани не является иммуногистохимическим критерием, а злокачественность определяют по комплексу признаков.'),
  (E'6eeab34c-3521-4c3a-b423-680587191222', E'31c6d869-9d1f-4fa8-8acb-1c1c558fe1e6', E'Патологические состояния иммунной системы связаны с нарушением регуляции иммунного ответа. При иммунодефицитах защитные механизмы ослаблены, при реакциях гиперчувствительности иммунный ответ становится чрезмерным или повреждает собственные ткани организма. Аутоиммунные заболевания развиваются вследствие утраты иммунологической толерантности к собственным антигенам. Некоторые формы амилоидоза связаны с длительной воспалительной стимуляцией и накоплением патологических белковых отложений в тканях.'),
  (E'a9a95b68-fbe8-4001-abaf-1da0ea627370', E'fe735722-b33b-49d9-89fd-3927e184eeb4', E'Аденоматозные полипы представляют собой неопластические разрастания слизистой оболочки толстой кишки на ножке или на широком основании. По определению, они характеризуются дисплазией и в зависимости от архитектоники желез подразделяются на тубулярные, тубулярно-ворсинчатые и ворсинчатые. Они являются предшественниками большинства случаев колоректальной аденокарциномы'),
  (E'3d236918-02f7-4710-9881-081054479b59', E'4fc34c16-116f-4d8b-b967-1ee20cd84f56', E'При антракозе вдыхаемые угольные частицы фагоцитируются макрофагами лёгких и могут переноситься в регионарные лимфатические узлы. Железосодержащий пигмент связан с распадом гемоглобина, меланин синтезируется меланоцитами, а кальциноз представляет собой отложение минеральных солей. Макрофаги захватывают частицы, которые попадают в дыхательные пути, а затем часть нагруженных пигментом клеток перемещается по лимфатическим путям. Поэтому угольный пигмент обнаруживают не только в лёгочной ткани, но и в регионарных лимфатических узлах; сам по себе антракоз не равнозначен некрозу.'),
  (E'85a9eb50-6f14-4bb1-b6ca-8e1ff0eb1db8', E'e84f73ce-0282-4fc1-95ba-834b7091c8c9', E'Общий гемосидероз возникает при избыточном поступлении или высвобождении железа, например при повторном внутрисосудистом гемолизе и многократных переливаниях крови. Однократное локальное кровоизлияние чаще вызывает местное отложение гемосидерина; холестаз связан с билирубином, а синтез меланина не приводит к перегрузке железом. При повторном разрушении эритроцитов или поступлении большого количества донорских эритроцитов железа может становиться больше, чем организм способен безопасно использовать и хранить. Пигмент откладывается в клетках системы мононуклеарных фагоцитов и других тканях; единичное кровоизлияние обычно вызывает локальный, а не распространённый процесс.'),
  (E'c8647970-dcd2-474a-88cd-ef3e2a6f2d0a', E'fdf85d5d-bc5f-4a12-a7c9-e923c685375c', E'При надпечёночной (гемолитической) желтухе усиленный распад эритроцитов увеличивает образование билирубина, и преимущественно неконъюгированная фракция превышает возможности печени по захвату и конъюгации. Снижение захвата или конъюгации связано с печёночными механизмами, а препятствие оттоку желчи вызывает подпечёночную желтуху. При гемолизе увеличивается поступление неконъюгированного билирубина к печени; в крови его концентрация возрастает, если печень не успевает захватывать и конъюгировать весь объём пигмента. Это отличает гемолитическую желтуху от печёночной, связанной с нарушением обработки билирубина гепатоцитами, и механической, возникающей при блокаде желчных путей.'),
  (E'4cd88440-5f10-4f92-86bf-3b175dfa697b', E'92b53917-222b-4a24-85a7-6318275dfd10', E'Гематоидин может формироваться в старых очагах кровоизлияния и, в отличие от гемосидерина, не содержит железа. Гемосидерин является железосодержащим продуктом переработки гемоглобина, билирубин связан с обменом желчных пигментов, а угольные частицы являются экзогенным пигментом. Гематоидин обычно имеет жёлто-оранжевые или золотистые кристаллические отложения в старых кровоизлияниях и формируется при распаде гемоглобина в условиях, где железо не сохраняется в составе пигмента. Поэтому наличие гематоидина не следует трактовать как доказательство накопления железа; для гемосидерина используют специальные реакции на железо.'),
  (E'5951240e-9b01-4cb4-8d4f-421360a0a461', E'56f5cd4a-aea5-48c1-b2b8-90742e4ba32a', E'Меланоз означает избыточное или необычное накопление меланина; значение изменения зависит от локализации, распространённости и причины. Билирубин вызывает желтушное окрашивание, гемосидерин связан с обменом железа, а липофусцин — с накоплением остаточных продуктов окисления в лизосомах. Меланоз может быть локальным или распространённым, врождённым или приобретённым; морфологическое значение определяется причиной и местом накопления пигмента. Его следует отличать от желтушного окрашивания при билирубинемии и от буроватых отложений гемосидерина, поскольку химическая природа пигмента и механизмы накопления различны.'),
  (E'e48b761e-66d5-4cce-92b1-47e4194b3c56', E'ee6854b7-3850-49ed-a7b2-2f4acdbe9acf', E'Дистрофическое обызвествление развивается в повреждённых, дегенерирующих или некротических тканях и обычно не требует повышения кальция крови. Отложение кальция в относительно сохранных тканях на фоне системного нарушения обмена соответствует метастатическому обызвествлению; железо и ураты образуют другие типы тканевых отложений. Кальциевые соли осаждаются в участках, где повреждены мембраны и изменён состав тканей, например в старых очагах некроза, атеросклеротических бляшках или повреждённых клапанах. Содержание кальция в крови при этом может оставаться нормальным, поскольку ключевое значение имеет локальное состояние ткани, а не системный избыток кальция.'),
  (E'97fa6af8-ae26-43d0-a5c9-e4f669462c1b', E'94a7d420-0972-4207-b280-c0d8f33bc260', E'Местный гемосидероз развивается в ограниченной области, где распадаются эритроциты, например в старом кровоизлиянии или при локальном хроническом венозном застое. Распространённое накопление железа соответствует общему гемосидерозу; билирубин вызывает желтушное окрашивание, а кальциевые соли относятся к обызвествлению. После распада эритроцитов гемоглобин поглощается макрофагами, а железо постепенно связывается и откладывается в виде гемосидерина. Местное накопление часто сопровождает рассасывание гематомы или хронический застой крови в определённом органе и не обязательно означает системную перегрузку железом.'),
  (E'b2e8dd1e-51d9-456d-9c59-28d9866be347', E'd1dab216-4b6f-4d36-a4c4-bb7a466d9a87', E'Желтушное окрашивание обусловлено накоплением билирубина в крови и тканях. Гемосидерин связан с обменом железа, липофусцин накапливается в лизосомах долгоживущих клеток, а гематоидин может образовываться в старых очагах кровоизлияния и не содержит железа. Билирубин образуется при распаде гема, переносится в печень, там конъюгируется и выводится с желчью. Если его образование превышает возможности переработки или нарушается печёночное выведение либо отток желчи, пигмент накапливается в крови и тканях, придавая им жёлтую окраску.'),
  (E'428c59c9-5042-411d-80b7-52711b941354', E'6cfcb876-f733-4356-9316-e1f10591e203', E'При холестазе нарушается образование или отток желчи, поэтому желчные пигменты задерживаются в гепатоцитах и канальцах; могут формироваться желчные тромбы. Преимущественное накопление неконъюгированного билирубина типичнее для гемолитического механизма, а гемосидерин в макрофагах отражает переработку гемоглобина, а не застой желчи. При микроскопическом исследовании желчные тромбы представляют собой скопления густой желчи в канальцах, иногда с пигментом в цитоплазме гепатоцитов. Этот признак отражает застой желчи и нарушение её оттока, а не усиленное разрушение эритроцитов или накопление железосодержащего пигмента.'),
  (E'a36d93df-df50-4bca-b579-db9505b602bb', E'2c67bafd-27ba-4f00-9f2a-834a7665cb89', E'Меланин синтезируется меланоцитами, формирует окраску кожи, волос и радужки и поглощает часть ультрафиолетового излучения. Желтуха связана с билирубином, обмен железа — с ферритином и гемосидерином, а остаточные лизосомальные гранулы характерны для липофусцина. Меланин образуется в меланоцитах и передаётся соседним клеткам эпидермиса, где влияет на окраску тканей. Поглощая часть ультрафиолетового излучения, он уменьшает его повреждающее действие, хотя не обеспечивает полной защиты от солнца; его количество зависит от активности меланоцитов и регуляции меланогенеза.'),
  (E'5c0fa65c-7367-4f7b-a6e0-3291f5582883', E'b5a201fc-9d6e-4b9e-908f-835bc7944077', E'Бурая атрофия сочетает уменьшение объёма органа с буроватой окраской из-за накопления липофусцина, например в миокарде при старении или истощении. Билирубин вызывает желтушность, гемосидерин придаёт ржаво-бурый оттенок при отложении железа, а угольные частицы связаны с антракозом. При бурой атрофии орган уменьшается в объёме, а липофусцин придаёт его ткани буроватый оттенок; классический пример — миокард у пожилых или истощённых людей. Это сочетание атрофии и пигментации отличается от желтухи, при которой накапливается билирубин, и от гемосидероза, при котором откладывается железосодержащий пигмент.'),
  (E'78e3e3cd-659f-4284-8f06-d0e20e211515', E'1c9f71c0-d01c-420d-ab55-6a1d33fab02b', E'При метастатическом обызвествлении кальциевые соли часто откладываются в почках, лёгких, слизистой желудка и стенках сосудов из-за системных нарушений обмена. Старые некротические очаги при нормальном уровне кальция более характерны для дистрофического кальциноза; макрофагальное накопление железа и синтез меланина относятся к другим процессам. Распределение отложений связано с особенностями местной среды и кислотно-основного состояния тканей; при системных нарушениях обмена соли кальция нередко обнаруживают в интерстиции почек, альвеолярных перегородках лёгких, слизистой желудка и сосудистых стенках. Эти локализации помогают распознать системный характер процесса, но сами по себе не указывают на единственную причину гиперкальциемии.'),
  (E'be74b242-99f3-4f66-abe4-40358da0511f', E'9fef2204-2604-41db-8833-79f832e6ad60', E'По биологическому значению различают физиологическую регенерацию, поддерживающую нормальное обновление; репаративную, восполняющую повреждение; и патологическую, протекающую чрезмерно, недостаточно или с изменением направления восстановления. Клеточная и внутриклеточная формы описывают механизм, реституция и субституция — результат, а ишемическая, компрессионная и дисгормональная — причины атрофии.'),
  (E'99dfcfce-a85b-422f-8c29-10b1b9271838', E'fccc68b7-0035-4040-92cd-aefb9cc33b17', E'Гемохроматоз характеризуется избыточным накоплением железа в органах, особенно в печени, поджелудочной железе, сердце и эндокринных структурах; длительная перегрузка может приводить к клеточному повреждению, фиброзу и органной дисфункции. Нарушение обмена билирубина вызывает желтуху, локальный гемосидероз ограничен очагом, а порфирии связаны с нарушением синтеза гема, а не с тканевой перегрузкой железом. Наиболее выраженные изменения часто возникают в печени, где железо может накапливаться в гепатоцитах, а при длительном процессе развиваются повреждение клеток и фиброз. Поражение поджелудочной железы, сердца и эндокринных органов способно нарушать их функцию; поэтому гемохроматоз отличается от простого локального отложения пигмента клинической значимостью и распространённостью.'),
  (E'7523272a-7cd4-475e-a041-43d740506570', E'c8f77232-3318-4ef7-87a4-1851f61255c3', E'Механическая желтуха возникает при препятствии оттоку желчи, например из-за камня, опухоли или стриктуры; в крови обычно повышается конъюгированный билирубин. Ускоренный распад эритроцитов характерен для гемолитической желтухи, а нарушение захвата или конъюгации — для печёночных вариантов. Причиной могут быть камень общего желчного протока, опухоль, рубцовое сужение или другое препятствие в желчных путях. Задержка конъюгированного билирубина приводит к его поступлению в кровь; нередко одновременно повышаются показатели холестаза, а длительное нарушение оттока желчи повреждает печень.'),
  (E'8f701fe4-379c-4a6d-ab1a-fc3e26cec5ed', E'c4ffc6a5-e869-4b23-83ee-4f8943ef4dd6', E'Порфирины — циклические соединения, участвующие в биосинтезе гема; нарушения ферментативных этапов этого пути могут приводить к накоплению порфиринов или их предшественников. Запасание железа связано с ферритином и гемосидерином, конъюгация — с метаболизмом билирубина, а продукты окисления липидов участвуют в образовании липофусцина. Порфирины участвуют в образовании гема — компонента гемоглобина, миоглобина и ряда ферментов. При нарушении отдельных ферментативных этапов синтеза гема могут накапливаться порфирины или их предшественники, что вызывает характерные проявления порфирий; это не то же самое, что избыток железа или нарушение обмена билирубина.'),
  (E'a929c932-f44c-4b31-b305-8096b945bd18', E'bdef6d6e-ae08-4ba5-9f60-354f5baa82c3', E'Липофусцин образуется из остаточных продуктов окисления липидов и белков и накапливается в лизосомах долгоживущих клеток, особенно при старении и хроническом окислительном стрессе. Гемосидерин связан с железом, билирубин задерживается при нарушениях его обмена или оттока желчи, а меланин синтезируется меланоцитами. Липофусцин представляет собой жёлто-коричневые гранулы остаточного материала, который накапливается в лизосомах при неполном удалении продуктов клеточного обмена. Особенно заметен он в кардиомиоцитах и гепатоцитах при старении, истощении или длительном окислительном стрессе; само его присутствие не всегда означает самостоятельное тяжёлое заболевание.'),
  (E'89fcb18a-8ab7-4f91-bd26-df10c0079def', E'7975d035-259b-414e-ac26-335103c73124', E'Метастатическое обызвествление связано с системным повышением доступности кальция или нарушением кальций-фосфорного обмена, например при гиперпаратиреозе или некоторых заболеваниях почек. Локальный кальциноз повреждённой ткани при нормальном кальции крови типичен для дистрофического обызвествления, а билирубин не является причиной кальцификации. Гиперкальциемия может возникать при гиперпаратиреозе, разрушении костной ткани и некоторых опухолевых процессах; нарушения фосфатного обмена, в том числе при хронической болезни почек, также создают условия для кальцификации. В отличие от дистрофического процесса, при метастатическом обызвествлении отложения возникают в тканях, которые до этого не обязательно были некротизированы.'),
  (E'98b726d8-eb02-4c3f-9f6d-38fed3446f64', E'9d6cd9d7-bde3-48cc-996b-0eb439f38a51', E'Некроз — прижизненная гибель клеток или участка ткани с необратимыми изменениями, включая повреждение мембран и изменения ядра. Обратимое повреждение ещё не означает гибели; апоптоз представляет собой регулируемую программируемую гибель, а увеличение числа клеток называется гиперплазией. Некротические клетки теряют способность поддерживать целостность мембран и нормальный обмен, а ферменты разрушают клеточные структуры. Вокруг очага обычно развивается воспалительная реакция, поскольку содержимое повреждённых клеток попадает во внеклеточную среду; при апоптозе процесс регулируется иначе и обычно не сопровождается столь выраженным воспалением.'),
  (E'61ebf849-8e92-4aa6-985b-abcfc8f6856b', E'94fa146b-f174-452a-93d4-10a6cdc7c15e', E'Реакция Перлса (берлинская лазурь) выявляет трёхвалентное железо в гемосидерине и окрашивает железосодержащие гранулы в синий цвет. ШИК-реакция выявляет определённые углеводные структуры, судановые красители применяют для липидов, а окраска по Цилю—Нильсену предназначена для кислотоустойчивых микроорганизмов. При реакции Перлса трёхвалентное железо взаимодействует с реагентами с образованием синего соединения, благодаря чему железосодержащие гранулы становятся хорошо различимыми. Метод используют для выявления гемосидерина в тканях; ШИК-реакция предназначена для выявления ряда углеводсодержащих структур, а судановые красители применяют для липидов.'),
  (E'42d6d416-fc55-40ed-8ac2-b23f9dd5da84', E'2fecf549-36ba-4551-ae8e-21593f52190e', E'При коагуляционном некрозе денатурация белков замедляет аутолиз, поэтому контуры ткани некоторое время сохраняются, хотя ядра исчезают. Быстрое разжижение характерно для колликвационного некроза, творожистые массы — для казеозного, а фибриноидный некроз поражает преимущественно сосудистые стенки и соединительную ткань. Коагуляционный некроз типичен для ишемии большинства плотных органов, включая сердце, почки и селезёнку. Денатурация структурных белков и ферментов замедляет ферментативное переваривание, поэтому ткань некоторое время сохраняет очертания клеток, хотя жизнеспособность утрачена и ядра подвергаются распаду.'),
  (E'a0c38049-e60e-4f49-ac94-ffbc1b6cfef2', E'44b340ad-70a4-45e4-9a2f-4d4986597117', E'Гангрена — клинико-морфологическая форма некроза, часто затрагивающая конечности, кишечник или лёгкие и сопровождающаяся изменением цвета ткани; при влажной форме существенную роль играет инфекция. Не каждый инфаркт называют гангреной, обратимое повреждение не является некрозом, а изолированное накопление пигмента не означает гибели ткани. Термин «гангрена» описывает некроз с характерными макроскопическими изменениями, часто в тканях, контактирующих с внешней средой или сообщающихся с ней. Сухая форма связана преимущественно с обезвоживанием ишемизированной ткани, а влажная — с отёком и быстрым распадом, нередко при участии микроорганизмов; поэтому клиническое течение этих форм различается.'),
  (E'bdf767c9-35a0-47b8-9883-7b9373838b42', E'b777991f-e87c-407b-9ce1-6fdf7fcf3477', E'Инфаркт — очаг некроза, возникающий при резком прекращении или критическом снижении кровоснабжения, чаще из-за тромбоза или эмболии; иногда причиной становится нарушение венозного оттока. Кровоизлияние может сопровождаться вторичным накоплением гемосидерина, обратимая ишемия не является инфарктом, а колликвационный тип некроза не определяет инфаркт сам по себе. Инфаркт обычно связан с тромбозом или эмболией артерии, но может возникнуть и при выраженном нарушении венозного оттока либо резком падении перфузии. Размер и вид очага зависят от типа кровоснабжения органа, скорости развития ишемии и наличия коллатералей; в большинстве плотных органов формируется коагуляционный некроз.'),
  (E'2e09fd82-2ce5-463d-9248-f57d9c16fa3b', E'2a1fa8e4-20ca-4fcf-a441-b010e96e6c19', E'После инфаркта некротические массы обычно удаляются клетками воспаления, а дефект замещается соединительной тканью с формированием рубца. В головном мозге некротическая ткань подвергается колликвации, и после её удаления может остаться киста. Полное восстановление архитектуры крупного инфаркта обычно невозможно; нагноение и общий гемосидероз не являются обязательными исходами. Организация инфаркта включает удаление некротических масс макрофагами и замещение дефекта соединительной тканью. В миокарде, почке и селезёнке обычно формируется рубец; в головном мозге из-за колликвационного расплавления может оставаться полость-киста. Полное восстановление исходной тканевой архитектуры после обширного инфаркта, как правило, невозможно.'),
  (E'90069419-473a-4bae-8132-2980c359a66b', E'7bcca841-61a6-45c1-a73f-dca1100f0684', E'При клеточной регенерации утраченные клетки восполняются делением сохранившихся клеток или клеток-предшественников, поэтому увеличивается число клеток. Внутриклеточная регенерация обновляет органеллы и молекулярные компоненты без обязательного увеличения клеточной популяции. Субституция означает замещение дефекта соединительной тканью, а метаплазия — смену одного зрелого клеточного типа другим; ни один из этих процессов не равнозначен клеточному восполнению.'),
  (E'ede649d1-b77c-4ab4-a316-a51f95814b42', E'71b57c4c-e01a-425e-b306-ca71c59574ea', E'При некрозе классически описывают кариопикноз (сморщивание и уплотнение ядра), кариорексис (фрагментацию) и кариолизис (растворение ядерного материала). Митоз и метаплазия не являются стадиями распада ядра, а обратное восстановление структуры ядра не соответствует необратимому некротическому повреждению. Эти изменения отражают последовательную деградацию ядерного материала: сначала ядро уплотняется и уменьшается, затем распадается на фрагменты, после чего хроматин теряет окрашиваемость и ядро исчезает. На практике стадии могут перекрываться, а их выраженность зависит от типа ткани и времени после повреждения.'),
  (E'55439946-1264-4de1-b551-af9fde586c6d', E'36487213-6830-487b-9550-c51b1a660c34', E'Для туберкулёзного очага типичен казеозный некроз: центральная масса выглядит рыхлой и крошковатой, нормальная архитектура ткани утрачивается; по периферии часто располагаются эпителиоидные клетки, лимфоциты и гигантские клетки. Коагуляционный некроз характерен для инфарктов многих плотных органов, колликвационный — для размягчения ткани, а жировой некроз связан с повреждением жировой ткани. Казеозный некроз имеет аморфный, зернистый, крошковатый вид и часто располагается в центре туберкулёзной гранулёмы. Вокруг очага могут находиться эпителиоидные клетки, лимфоциты и многоядерные гигантские клетки; в отличие от коагуляционного некроза, обычная архитектура ткани в центральной зоне утрачивается.'),
  (E'796f46f7-f882-4ae6-b512-5b986e93dc2a', E'dac6458b-ca65-4431-89ab-c1cb83dc4325', E'Влажной гангрене способствуют ишемия, отёк и присоединение инфекции, ускоряющей распад тканей; границы некроза могут быть нечёткими, а риск системных осложнений высок. Постепенное высыхание с мумификацией характерно для сухой гангрены, липофусцин связан с бурой атрофией, а холестаз не вызывает гангрену. Влажная гангрена чаще развивается при быстром нарушении кровоснабжения с выраженным отёком и микробным инфицированием. Ткань становится набухшей, размягчённой и зловонной, граница некроза часто плохо различима; из-за всасывания токсинов и распространения инфекции возможны тяжёлые системные осложнения.'),
  (E'04ad6836-507d-4d55-9933-a67c70771653', E'8db028e9-1748-4a0c-accb-77281050a2e0', E'Красный инфаркт вероятнее при венозной окклюзии, двойном кровоснабжении или в рыхлой ткани, например в лёгком, где повреждённая область может пропитываться кровью. При окклюзии конечной артериальной ветви в плотных органах чаще возникает белый инфаркт; гемосидероз и кальциноз могут быть вторичными изменениями, но не определяют тип инфаркта. Красный инфаркт возникает, когда кровь поступает в повреждённую область или пропитывает её после нарушения оттока. Это возможно при венозной окклюзии, двойном кровоснабжении и в рыхлой ткани; примером служит лёгкое, где кровоизлияние в зону некроза связано с особенностями сосудистой сети.'),
  (E'fb5ba8cc-7ed5-4d7c-82d9-39293342cd53', E'3c57069d-376c-4915-bc35-307ac5c8ae5e', E'К стромально-сосудистым диспротеинозам относятся мукоидное набухание, фибриноидное набухание и гиалиноз. Эти процессы затрагивают преимущественно межклеточное вещество и волокнистые структуры соединительной ткани, а также стенки сосудов. Гиалиново-капельная и гидропическая дистрофии относятся к паренхиматозным изменениям клеток, а роговая дистрофия — к нарушению ороговения эпителия. Стеатоз, ожирение и гликогеноз связаны с обменом липидов или углеводов; меланоз, гемосидероз и желтуха относятся к нарушениям обмена пигментов. При оценке классификации важно различать изменения межклеточного вещества и волокон соединительной ткани от внутриклеточных дистрофий паренхиматозных клеток. Мукоидное и фибриноидное набухание отражают разные по глубине стадии дезорганизации соединительной ткани, а гиалиноз характеризуется образованием плотных однородных масс.'),
  (E'1a508106-420a-434a-8683-5f8b7a625e87', E'8c55b381-8667-4741-9c6d-1df085aa9701', E'Для восстановления эпителия важны жизнеспособные резервные клетки и сохранный каркас, особенно базальная мембрана, которая направляет миграцию и упорядоченное восстановление покрова. Разрушение стромы нарушает архитектурную основу и повышает вероятность рубцевания. Предварительный рубец не является условием нормальной эпителизации, а инфекция и повторный некроз обычно продлевают воспаление и тормозят восстановление.'),
  (E'13c5d885-6f2b-4345-88fe-ca305acee4a3', E'9e1c4404-68cb-4087-9663-fbaf8cf1dd9d', E'Колликвационный некроз характеризуется преобладанием ферментативного переваривания, поэтому ткань размягчается и разжижается; классический пример — ишемическое повреждение головного мозга. При коагуляционном некрозе контуры некоторое время сохраняются, казеозный имеет творожистый вид, а фибриноидный поражает соединительную ткань и сосудистые стенки. Колликвационный некроз возникает, когда ферментативное переваривание преобладает над денатурацией белков; ткань становится мягкой, распадается и может превращаться в жидкую массу. Он характерен для инфаркта головного мозга, а при бактериальной инфекции сходный механизм участвует в образовании гнойного расплавления ткани.'),
  (E'10bc2af8-fd6f-4fc4-93db-08ebb48180e6', E'33ca86be-704f-4082-bbe5-26312d090e7d', E'При сухой гангрене ишемизированная ткань постепенно теряет воду, уплотняется, темнеет и мумифицируется; граница с жизнеспособными тканями часто выражена. Отёк и распад с инфекцией характерны для влажной гангрены, ферментативное разжижение — для колликвационного некроза, а творожистая масса типична для казеозного некроза. Сухая гангрена обычно развивается при постепенном нарушении артериального кровоснабжения, например при атеросклерозе. Из-за потери воды ткань становится плотной и сморщенной, а демаркационная линия может отделять её от жизнеспособной области; при присоединении инфекции сухая форма может осложниться влажной.'),
  (E'9dff5a62-a165-4120-846b-51a3b4b86dce', E'297ed846-03f8-4c65-9a8d-5f67d0712f77', E'В почке и селезёнке обычно формируется белый ишемический инфаркт из-за особенностей кровоснабжения и плотной структуры ткани; очаг часто клиновидный и имеет коагуляционный тип некроза. Красный инфаркт вероятнее при венозной окклюзии, двойном кровоснабжении или в рыхлой ткани; полость не образуется немедленно и не является обязательной. Почки и селезёнка имеют преимущественно конечные артериальные ветви и плотную ткань, поэтому при закупорке сосуда обычно возникает клиновидный белый инфаркт. По периферии очага со временем может формироваться воспалительная демаркационная зона, а затем дефект замещается рубцовой тканью.'),
  (E'47981803-2c1f-4c7d-85b5-44e55dcc0f1c', E'bf6554c6-18ab-4f30-84a7-a9f86da3afb1', E'При мукоидном набухании изменяется основное вещество соединительной ткани: оно накапливает кислые гликозаминогликаны и становится более проницаемым. Глубокого разрушения волокон обычно нет, поэтому при устранении причины изменения могут регрессировать. Глубокая деструкция с образованием фибриноида характерна для фибриноидного набухания; отложение амилоида — отдельный патологический процесс; накопление триглицеридов в адипоцитах означает ожирение. При мукоидном набухании изменения поверхностные и затрагивают основное вещество соединительной ткани. Ключевое морфологическое отличие мукоидного набухания — накопление кислых гликозаминогликанов и повышение гидрофильности основного вещества при относительной сохранности коллагеновых волокон. Поэтому на этой стадии изменения обычно обратимы. Фибриноидное набухание, напротив, сопровождается выраженным повреждением волокнистых структур и плазматическим пропитыванием ткани.'),
  (E'aedee360-0bef-48db-ad80-1e3afaf0d80b', E'95bfabd4-f5ac-44be-9a68-c63b7c913db9', E'Фибриноидное набухание — глубокая дезорганизация соединительной ткани с повреждением волокон и образованием фибриноида. В очаге повышается проницаемость сосудов, плазменные белки пропитывают ткань, а коллагеновые и другие структуры подвергаются разрушению. Поверхностные изменения без выраженной деструкции характерны для мукоидного набухания; холестерин в макрофагах типичен для липидных поражений, например атеросклероза; увеличение числа адипоцитов относится к гиперпластическому ожирению, а не к повреждению соединительной ткани. Фибриноид формируется вследствие сочетания повреждения соединительной ткани, повышения сосудистой проницаемости и пропитывания очага белками плазмы, включая фибриноген и иммуноглобулины. Морфологически поражённые структуры теряют обычную волокнистую организацию и приобретают интенсивно окрашивающийся, однородный вид. Это отличает процесс от поверхностного мукоидного набухания.'),
  (E'4a319d9b-ea6c-46ae-9065-6e7162069f35', E'c1286b43-14b3-4a7c-9732-1012cf87ceb9', E'Амилоидоз — внеклеточное отложение амилоида в тканях и органах. При окраске конго красным амилоид даёт характерное яблочно-зелёное двулучепреломление в поляризованном свете; отложения нарушают архитектуру ткани и могут сдавливать клетки. Накопление жира в гепатоцитах — стеатоз; поверхностное набухание основного вещества — мукоидное набухание; кальций в стенке аорты означает кальцификацию. Амилоидоз представляет собой внеклеточное накопление патологического фибриллярного белка. Амилоид — патологический фибриллярный белковый материал, который откладывается преимущественно внеклеточно и нарушает нормальную архитектонику тканей. При окраске конго красным отложения приобретают характерное яблочно-зелёное двулучепреломление в поляризованном свете. Клинические проявления зависят от типа амилоидного белка, распределения отложений и того, насколько сильно нарушена функция поражённого органа.'),
  (E'89889342-995f-4823-9143-8bd42de745b6', E'798d4e37-8ed6-4974-94f9-23bc93da74ef', E'При AA-амилоидозе амилоидные фибриллы образуются из белка SAA — белка острой фазы, уровень которого повышается при длительном воспалении. В норме SAA участвует в реакции острой фазы; при хронической стимуляции часть его производных может неправильно сворачиваться и откладываться в тканях. Кератин, гемоглобин и коллаген IV типа не являются белком-предшественником AA-амилоида. Для AA-амилоидоза исходным белком служит SAA, концентрация которого повышается при хроническом воспалении. При хронической воспалительной стимуляции концентрация SAA длительно остаётся повышенной, что создаёт условия для образования и внеклеточного накопления AA-фибрилл. Сам по себе высокий уровень SAA не равнозначен доказанному амилоидозу: диагноз устанавливают по выявлению отложений и определению их типа. Кератин, гемоглобин и коллаген IV типа не являются белками-предшественниками AA-амилоида.'),
  (E'75962d2f-db31-4d5b-9e51-a24ed128161c', E'b5254a66-c004-4ab8-b8bc-97808e4a5702', E'При периретикулярном амилоидозе амилоид откладывается по ходу ретикулярных волокон и базальных мембран сосудов и желёз. Такое расположение характерно для стромы паренхиматозных органов и может нарушать питание и функцию окружающих клеток. Отложение по крупным коллагеновым пучкам характерно для периколлагенового варианта; внутриклеточное расположение в ядрах не соответствует типичному внеклеточному амилоиду; амилоидоз не ограничивается костной тканью. Термин описывает топографию внеклеточных отложений: амилоид располагается вдоль ретикулярного каркаса и базальных мембран, в том числе сосудов и железистых структур. Такое расположение может нарушать микроциркуляцию и обмен между кровью и паренхиматозными клетками, приводя к их атрофии. Периколлагеновый вариант отличается преимущественным отложением вдоль коллагеновых волокон и в соединительнотканных структурах.'),
  (E'f1cd0bc5-ef2a-49b4-841f-c26a1a55850b', E'a1ac0c84-c85d-4a9d-918c-25f15e3fc4d3', E'Периколлагеновый амилоидоз затрагивает соединительную ткань, адвентицию сосудов, миокард, скелетные мышцы, нервы и кожу. Отложения в межмышечной и периваскулярной соединительной ткани могут уплотнять ткани и нарушать работу поражённых структур. Клубочки почек характерны прежде всего для периретикулярного поражения, но не являются единственной локализацией периколлагенового амилоидоза; фолликулы селезёнки и базальные мембраны кишечных желёз не охватывают характерное распределение по коллагеновым структурам, мышцам, нервам и коже. Периколлагеновое распределение чаще затрагивает соединительнотканные структуры, включая адвентицию сосудов, межмышечную ткань, миокард, скелетные мышцы, нервы и кожу. Отложения могут делать ткани плотными и нарушать работу поражённых структур за счёт механического сдавления и замещения нормальной ткани. Это распределение не следует смешивать с преимущественным поражением клубочков и базальных мембран, характерным для периретикулярного варианта.'),
  (E'793314de-a33d-4d21-a043-c1e249721257', E'158c3657-c4d9-47fe-9fcf-570d7c483075', E'Реституция — восстановление ткани того же типа с максимально возможным возвращением её нормальной архитектоники и функции. При субституции дефект закрывается соединительной тканью, формируя рубец, а грануляционная ткань обычно является промежуточной стадией репарации, а не конечным восстановлением исходной паренхимы. Увеличение органа за счёт стромы на фоне атрофии паренхимы не означает регенерацию.'),
  (E'cb53035d-d67c-4fbe-a809-d4889c707d51', E'603ef47f-73d0-485b-b6c9-acce95b982cd', E'По происхождению выделяют первичный, наследственный, вторичный и старческий амилоидоз. В современной классификации также учитывают белок-предшественник амилоида, поскольку тип белка определяет причину болезни и подход к диагностике. Острый, подострый и хронический обозначают течение заболевания, а не основные формы амилоидоза по происхождению; гиперпластический и гипертрофический относятся к типам ожирения; простой и сложный гиалин — разновидности гиалина, не амилоидоза. Историческая классификация по происхождению удобна для описания первичных, наследственных, вторичных и старческих форм, однако для современной диагностики принципиально важно установить тип белка-предшественника. Например, AA-амилоид связан с белком SAA при хроническом воспалении, а AL-амилоид образуется из лёгких цепей иммуноглобулинов. Поэтому одинаковая морфологическая картина может иметь разные причины и требовать разного клинического подхода.'),
  (E'77b2cb71-c0bc-41ea-8308-5803aec7f955', E'bf49fc9b-1ff2-44e3-86a5-d7f09d4fdae7', E'При вторичном AA-амилоидозе часто поражаются почки; отложения амилоида в клубочках нарушают фильтрацию и могут приводить к протеинурии и почечной недостаточности. Поражение клубочков нередко проявляется потерей белка с мочой, а прогрессирование процесса снижает скорость клубочковой фильтрации. Щитовидная железа может поражаться при отдельных формах амилоидоза, но не во всех случаях; кожа и хрусталик не являются наиболее типичными органами при вторичном AA-амилоидозе. Почки часто поражаются с развитием протеинурии и нарушением фильтрации. Поражение клубочков приводит к нарушению фильтрационного барьера и появлению белка в моче; при прогрессировании возможны нефротический синдром и хроническая почечная недостаточность. Амилоид также может откладываться в сосудах и других структурах почки, усиливая нарушение функции. Другие органы могут поражаться при AA-амилоидозе, но почки относятся к наиболее клинически значимым локализациям.'),
  (E'011f5e5f-f311-4640-a96a-a504aa502022', E'c73e3a8d-6704-4989-a0d4-a14b9d841673', E'Периретикулярный амилоидоз преимущественно поражает печень, почки, селезёнку, надпочечники и кишечник. Отложения располагаются вдоль ретикулярного каркаса и сосудистых или железистых базальных мембран, поэтому часто вовлекаются органы с выраженной капиллярной сетью. Миокард и скелетные мышцы могут вовлекаться при периколлагеновом амилоидозе; кожа и периферические нервы также относятся к возможным местам периколлагеновых отложений; суставной хрящ не является единственной или основной локализацией периретикулярного варианта. При периретикулярном распределении часто вовлекаются органы с развитой сетью ретикулярных волокон, синусоидов, капилляров и базальных мембран. В печени и селезёнке отложения могут менять макроскопический вид органов, а в почках особенно значимо поражение клубочков. Перечень органов не означает, что все они обязательно поражаются одновременно: распространённость зависит от формы амилоидоза и длительности заболевания.'),
  (E'6ae38780-25df-4643-a72d-ef663003e47c', E'4e80f80e-09b9-4a31-a7ec-8f164fecb409', E'Отложения амилоида сдавливают и замещают паренхиму, вызывая атрофию клеток и склероз; функция органа постепенно снижается. Клинические проявления зависят от того, какие органы поражены и насколько выражены отложения. Амилоид не усиливает функцию органа; выраженные отложения не обеспечивают полного восстановления независимо от тяжести; увеличение числа адипоцитов относится к ожирению и не объясняет функциональные последствия амилоидоза. Выраженность функционального нарушения зависит от объёма отложений, локализации и исходного резерва органа. Амилоид может сдавливать клетки, нарушать микроциркуляцию и постепенно замещать нормальные тканевые структуры; поэтому поражение почек, сердца, печени или кишечника проявляется по-разному. Ранние изменения иногда мало выражены, но массивное и длительное накопление обычно приводит к хронической недостаточности поражённого органа.'),
  (E'5e3d92ed-94c4-4e90-86d3-80422112c4ee', E'742a0152-b9a4-48f7-ac6b-c4050a9f1818', E'Вторичный амилоидоз развивается на фоне хронических инфекций и гнойно-деструктивных заболеваний, а также некоторых опухолевых и ревматических болезней. Длительное воспаление повышает уровень белка SAA, из которого при AA-амилоидозе формируются амилоидные фибриллы. Врождённое происхождение характерно для некоторых наследственных форм, но не для вторичного амилоидоза; поражение не ограничено головным мозгом; вторичный амилоидоз по определению связан с длительными воспалительными или другими основными заболеваниями. Длительное воспаление стимулирует печень к повышенной продукции белка острой фазы SAA; из его производных при определённых условиях формируются AA-амилоидные фибриллы. К классическим фоновым состояниям относятся хронические гнойные инфекции и некоторые хронические воспалительные или ревматические заболевания. Вторичный амилоидоз не является врождённым по определению и может поражать несколько органов, особенно почки.'),
  (E'd273b617-20e6-42fc-b4b1-1a5cd521f3fa', E'eb2995f3-6b47-4d68-9c32-aadc04a3f7e0', E'Амилоид откладывается в клубочках, стенках сосудов, базальных мембранах канальцев и строме почек. По мере накопления отложений сдавливаются и атрофируются нефроны, развивается склероз, вследствие чего почки постепенно утрачивают функцию. Почки не обязательно уменьшаются с самого начала, а по мере накопления амилоида могут увеличиваться и уплотняться; жировая инфильтрация эпителия — другой процесс; отложения не ограничиваются лоханкой, а часто затрагивают клубочки, сосуды и базальные мембраны. На ранних и выраженных стадиях почки могут быть увеличенными, плотными и иметь восковидный или сальный вид; при длительном течении из-за атрофии нефронов и склероза возможно амилоидное сморщивание. Макроскопическая картина зависит от стадии и выраженности поражения, поэтому уменьшение почек не обязательно присутствует с самого начала. Микроскопически оценивают отложения в клубочках, сосудистых стенках, базальных мембранах и интерстиции.');
INSERT INTO public.question_answers (question_id, correct_option_id, explanation) VALUES
  (E'7323da51-8ddd-4448-aeb6-eaf786a66e64', E'67940c4b-798c-428e-b2be-f0693c48726a', E'При периколлагеновом амилоидозе амилоид откладывается вдоль коллагеновых волокон, в том числе в адвентиции сосудов. Расположение по ходу коллагенового каркаса отличает этот вариант от периретикулярного, при котором отложения связаны преимущественно с ретикулярными волокнами и базальными мембранами. Просвет канальцев не является типичным местом отложения амилоида; замещение только эпителия кишечника неверно, поскольку амилоид откладывается внеклеточно в строме и стенках сосудов; внутриклеточный жир относится к липидной дистрофии. Периколлагеновый вариант характеризуется внеклеточным расположением амилоида вдоль коллагеновых волокон, в соединительной ткани и адвентиции сосудов. Такое распределение отличается от периретикулярного, при котором отложения связаны главным образом с ретикулярными волокнами и базальными мембранами. Амилоид не является внутриклеточным жиром и не ограничивается просветами канальцев или эпителием отдельного органа.'),
  (E'ec18de1f-dc3f-4b2b-b520-77979be02f73', E'1b94e998-acf4-4b1f-9dc6-c20482f9df8c', E'При амилоидозе печень может быть увеличенной, плотной и иметь сальный вид. Амилоид откладывается в строме и стенках сосудов, сдавливает печёночные балки и способствует атрофии гепатоцитов; при выраженном поражении может снижаться функция печени. Уменьшение, сухость и зернистость не являются типичным макроскопическим видом печени при выраженном амилоидозе; зелёная окраска не связана с амилоидом; превращение органа в полость с жиром не является морфологическим проявлением амилоидоза. При выраженном амилоидозе печень обычно увеличивается и становится плотной; на разрезе она может выглядеть бледной, восковидной или сальной. Отложения в пространстве Диссе, синусоидах и сосудистых структурах могут сдавливать печёночные балки и способствовать атрофии гепатоцитов. Внешний вид не является достаточным для подтверждения диагноза: требуется морфологическое исследование с окраской на амилоид и, по возможности, типированием отложений.'),
  (E'd8caa10c-41cd-48e3-9590-76380fe4dd9d', E'15805a4a-87ce-4b24-8150-fefe8fd7355c', E'При амилоидозе селезёнка может иметь саговый вид при преимущественном отложении амилоида в фолликулах или сальный вид при более распространённом отложении в красной пульпе. При саговой форме фолликулы выступают на разрезе как полупрозрачные зёрна, а при сальной орган выглядит более равномерно плотным и блестящим. Бурая атрофия связана с накоплением липофусцина и уменьшением органа; казеозный некроз характерен для отдельных инфекционных процессов; гидропическая дистрофия означает внутриклеточное накопление воды. Саговый и сальный вид селезёнки отражают разные варианты распределения амилоида. При саговой селезёнке амилоид преимущественно откладывается в лимфоидных фолликулах белой пульпы, поэтому на разрезе видны полупрозрачные зернистые участки, напоминающие зёрна саго. При сальной форме отложения более диффузно вовлекают красную пульпу, из-за чего селезёнка выглядит увеличенной, плотной и блестящей. Эти макроскопические варианты отражают различное распределение амилоида, но для подтверждения необходима микроскопия.');



--
-- Data for Name: question_comments; Type: TABLE DATA; Schema: public; Owner: -
--

-- Imported 1 rows into public.question_comments
INSERT INTO public.question_comments (id, question_id, user_id, comment, created_at) VALUES
  (E'3ffbf35d-bed0-408c-ad7d-9dbf17b816ad', E'a9a95b68-fbe8-4001-abaf-1da0ea627370', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'нормально', E'2026-10-26 22:12:07.599147+00');



--
-- Data for Name: question_favorites; Type: TABLE DATA; Schema: public; Owner: -
--

-- Imported 4 rows into public.question_favorites
INSERT INTO public.question_favorites (user_id, question_id, created_at) VALUES
  (E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'b64549c8-77a0-42fe-bb0a-302d34910c04', E'2026-10-29 20:36:15.558759+00'),
  (E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'aea35f40-df09-464f-87b3-53054d544739', E'2026-10-29 20:36:19.544903+00'),
  (E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'e42319a0-9585-4068-aba3-dd3b082d9ee4', E'2026-11-04 00:00:17.881722+00'),
  (E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'7c368354-ed4d-4e5c-9f5a-235b531a3ad1', E'2026-11-04 17:26:02.619982+00');



--
-- Data for Name: question_options; Type: TABLE DATA; Schema: public; Owner: -
--

-- Imported 1612 rows into public.question_options
INSERT INTO public.question_options (id, question_id, option_text, sort_order) VALUES
  (E'81d7be2f-0987-4963-b117-e6832bd91f9a', E'7c07057a-982d-418f-abe5-c26649151f65', E'Нарушение кровообращения, приводящее исключительно к отёку тканей.', E'0'),
  (E'83b329a1-925f-4dbe-b564-846308359244', E'7c07057a-982d-418f-abe5-c26649151f65', E'Патологический процесс, обусловленный нарушением клеточного/тканевого метаболизма и сопровождающийся структурными изменениями.', E'1'),
  (E'124105b0-9a97-40dd-a629-a6b1167f2dc4', E'7c07057a-982d-418f-abe5-c26649151f65', E'Компенсаторное увеличение числа клеток без изменения обмена.', E'2'),
  (E'8f9766a1-c1b4-47a3-8ed5-8f2e7d00829c', E'7c07057a-982d-418f-abe5-c26649151f65', E'Только необратимая гибель ткани.', E'3'),
  (E'6968be5c-20a1-4edd-8398-284efd92b4d9', E'056d6796-3437-49aa-a2e1-8b83cb6e7f5e', E'Только по цвету органа и возрасту пациента.', E'0'),
  (E'2484ccc4-1353-4067-9e75-c81c14f00ea9', E'056d6796-3437-49aa-a2e1-8b83cb6e7f5e', E'По локализации изменений, виду нарушенного обмена, распространённости и происхождению.', E'1'),
  (E'6d48f9b8-429d-45bc-b0e1-e328a1680b25', E'056d6796-3437-49aa-a2e1-8b83cb6e7f5e', E'Только по наличию воспаления.', E'2'),
  (E'ae23b528-69ee-4cfc-87d9-c6e826476dd7', E'056d6796-3437-49aa-a2e1-8b83cb6e7f5e', E'По форме органа и характеру кровоснабжения.', E'3'),
  (E'50a1d9c6-4378-4182-91a1-851e1c95dc37', E'c0edcfb3-1a0f-4254-98f7-1ada8b44efe7', E'Инфильтрация.', E'0'),
  (E'4753bc8c-d9d1-4e83-9c29-f0e0c0f3694c', E'c0edcfb3-1a0f-4254-98f7-1ada8b44efe7', E'Декомпозиция (фанероз).', E'1'),
  (E'bf04f53c-335b-4e49-b1c2-8bf19ab4d149', E'c0edcfb3-1a0f-4254-98f7-1ada8b44efe7', E'Извращённый синтез.', E'2'),
  (E'32d25f67-dc07-4512-b8e4-6918f669469e', E'c0edcfb3-1a0f-4254-98f7-1ada8b44efe7', E'Эмболия.', E'3'),
  (E'2ef6bcba-aa7d-42ca-a3c2-73ae0b3236c0', E'e42319a0-9585-4068-aba3-dd3b082d9ee4', E'Трансформация.', E'0'),
  (E'7e8c8e84-5421-4ea1-8bd4-2a9386536375', E'e42319a0-9585-4068-aba3-dd3b082d9ee4', E'Инфильтрация.', E'1'),
  (E'47a45bde-5515-4003-b45f-cc9b2500eea7', E'e42319a0-9585-4068-aba3-dd3b082d9ee4', E'Декомпозиция (фанероз).', E'2'),
  (E'e377b220-6f9f-46eb-aba7-caec93d98a7b', E'e42319a0-9585-4068-aba3-dd3b082d9ee4', E'Извращённый синтез.', E'3'),
  (E'4df5c206-3646-42ec-83cb-6e00accdaccd', E'7c368354-ed4d-4e5c-9f5a-235b531a3ad1', E'Аденоматозный полип толстой кишки', E'0'),
  (E'd4a7270c-dfed-4416-89ec-fad2be40fb62', E'7c368354-ed4d-4e5c-9f5a-235b531a3ad1', E'Аденокарцинома желудка', E'1'),
  (E'17a31d69-36aa-42ec-b188-762f707d9992', E'7c368354-ed4d-4e5c-9f5a-235b531a3ad1', E'Аденокарцинома толстой кишки', E'2'),
  (E'93b27970-86b9-4cb8-8875-8cbe3a79353e', E'7c368354-ed4d-4e5c-9f5a-235b531a3ad1', E'Дивертикулез', E'3'),
  (E'7ad0a7be-8ebe-4c40-8e6a-7d88ebaf66ab', E'6b241cf2-b8f8-4400-80f0-a360cb7cd3a5', E'Многочисленные липидные капли, окрашенные Суданом III.', E'0'),
  (E'753f88d7-cb64-40fb-98c7-c93fdbcba58b', E'6b241cf2-b8f8-4400-80f0-a360cb7cd3a5', E'Крупные гиалиноподобные белковые капли в цитоплазме клеток.', E'1'),
  (E'a7fbefaf-b993-47b0-9506-079013416831', E'6b241cf2-b8f8-4400-80f0-a360cb7cd3a5', E'Только увеличение количества коллагеновых волокон в строме.', E'2'),
  (E'e8ccf769-47c7-4bdb-96fb-7b7b53d9d44c', E'6b241cf2-b8f8-4400-80f0-a360cb7cd3a5', E'Кальциевые отложения в межклеточном веществе.', E'3'),
  (E'a6ff442e-ba67-4ce7-9e6e-482252ecf31d', E'20294443-8ae8-45ac-8630-9e2a2f99fa78', E'Всегда полное восстановление без повреждения клетки.', E'0'),
  (E'471d2b4a-4197-42c9-ae31-8233d1e3b729', E'27b610f6-dc90-4721-83f5-d6c6cb2d8762', E'Преимущественное нарушение обмена веществ в паренхиматозных клетках без изменений стромы', E'0'),
  (E'9119120c-1397-4ab3-8665-761ead480679', E'27b610f6-dc90-4721-83f5-d6c6cb2d8762', E'Нарушение обмена сложных веществ с проявлениями в паренхиме и строме или межклеточном веществе', E'1'),
  (E'5f96d66d-f5d6-4c1f-ba6f-9eae547b334f', E'6ba889cb-f5b3-40ba-8f03-8a2594888776', E'Первичное разрушение ворсинок тонкой кишки', E'0'),
  (E'26064282-8605-4634-8de1-6763e85a08e0', E'6ba889cb-f5b3-40ba-8f03-8a2594888776', E'Гипертрофия слизистой оболочки толстой кишки', E'1'),
  (E'f6a70a15-7431-4f45-9356-4ec344bae385', E'6ba889cb-f5b3-40ba-8f03-8a2594888776', E'Врождённое отсутствие ганглиозных клеток в интрамуральных нервных сплетениях поражённого сегмента', E'2'),
  (E'886ed742-a00e-4a0a-9d20-8f9adb1895b0', E'6ba889cb-f5b3-40ba-8f03-8a2594888776', E'Врождённое расширение кровеносных сосудов кишечника', E'3'),
  (E'd0beaeb2-75b8-45d9-abba-d9f586f529cc', E'df8943c1-eeb5-4388-b407-1221c464d8d5', E'Обязательное образование множественных аденом', E'0'),
  (E'abeb9d55-3945-44b3-b4f7-a4ab7f69e928', E'df8943c1-eeb5-4388-b407-1221c464d8d5', E'Первичное развитие лимфомы', E'1'),
  (E'd35e8046-4074-45bb-9a16-3320de98265e', E'df8943c1-eeb5-4388-b407-1221c464d8d5', E'Изолированное поражение серозной оболочки без повреждения слизистой', E'2'),
  (E'2a8f1c12-7d22-4991-afc3-f9e2561fc52e', E'df8943c1-eeb5-4388-b407-1221c464d8d5', E'Повреждение и слущивание эпителия слизистой оболочки при относительной сохранности крипт на ранних этапах', E'3'),
  (E'deadfff5-944a-4bb3-a14b-ff011fa2cd03', E'18bc9b49-e108-4248-abaf-5e169098cbea', E'Диффузное разрастание фиброзной ткани в подслизистом слое', E'0'),
  (E'ae27ed90-d266-45ed-91cf-c5c8c06812d4', E'18bc9b49-e108-4248-abaf-5e169098cbea', E'Множественные гранулёмы с казеозным некрозом', E'1'),
  (E'fa682234-66d5-471f-88e0-eb8e1a62f359', E'18bc9b49-e108-4248-abaf-5e169098cbea', E'Расширенные тонкостенные сосуды слизистой и подслизистой оболочек', E'2'),
  (E'd327a739-8a77-4d26-8c38-a5bf099b09f6', E'18bc9b49-e108-4248-abaf-5e169098cbea', E'Врождённое отсутствие нервных ганглиев', E'3'),
  (E'55a45c9a-51c7-4d77-a380-3f3a4f8fce7c', E'f7e90987-c01e-46c5-9f9a-f09022ff1fb2', E'Хроническое воспаление червеобразного отростка', E'0'),
  (E'e7aebca4-9c45-4203-b565-9a4389ed1b24', E'f7e90987-c01e-46c5-9f9a-f09022ff1fb2', E'Незаращение остатка желточного протока', E'1'),
  (E'c6d23e0f-985a-4492-95a8-a55f564c8b3e', E'f7e90987-c01e-46c5-9f9a-f09022ff1fb2', E'Врождённое отсутствие мышечной оболочки желудка', E'2'),
  (E'6f523295-c58f-41b0-9a1c-53088a90dd84', E'f7e90987-c01e-46c5-9f9a-f09022ff1fb2', E'Тромбоз мезентериальных артерий', E'3'),
  (E'a9bfd4e0-c5de-4fdc-9074-b166cded81ca', E'bda40b0d-d4e6-496e-a2d0-ca19d0e38a76', E'Полное отсутствие просвета на определённом участке кишки', E'0'),
  (E'5ae5e396-1df7-4ca4-a08f-4775ee0207cc', E'bda40b0d-d4e6-496e-a2d0-ca19d0e38a76', E'Расширение просвета кишки вследствие атонии', E'1'),
  (E'6d08342e-e017-40d3-99ff-19577db71470', E'bda40b0d-d4e6-496e-a2d0-ca19d0e38a76', E'Множественные язвы слизистой оболочки', E'2'),
  (E'5ef41f72-a71e-4626-924c-33145e7921bf', E'bda40b0d-d4e6-496e-a2d0-ca19d0e38a76', E'Разрастание лимфоидной ткани в стенке кишки', E'3'),
  (E'3db29956-81e8-457a-9c38-683cf85e9569', E'81612ea5-581a-4671-9a40-dfc9df29c95a', E'Аденокарцинома из ворсинчатой ​​аденомы', E'0'),
  (E'583c56a9-63ee-4b14-bf3b-8d7f32052080', E'81612ea5-581a-4671-9a40-dfc9df29c95a', E'Одиночный дивертикул ободочной кишки', E'1'),
  (E'bdd57ec8-a5dc-47a3-bf39-f323e04aeb1a', E'81612ea5-581a-4671-9a40-dfc9df29c95a', E'Гиперпластический полип', E'2'),
  (E'3329a09e-4807-4542-92b4-7d9103e6437e', E'81612ea5-581a-4671-9a40-dfc9df29c95a', E'Лимфофолликулярная гиперплазия слизистой оболочки', E'3'),
  (E'c3c8c3a8-6b70-4eb0-8928-f4ae7f1c03b9', E'20294443-8ae8-45ac-8630-9e2a2f99fa78', E'Обязательное образование рубца без гибели клеток.', E'1'),
  (E'6c89c55a-0786-4a79-862c-e32df79d730d', E'20294443-8ae8-45ac-8630-9e2a2f99fa78', E'Гибель клетки.', E'2'),
  (E'4b8ada64-6215-461f-b09a-827aaf8cd6cb', E'20294443-8ae8-45ac-8630-9e2a2f99fa78', E'Переход в жировую дистрофию во всех случаях.', E'3'),
  (E'bf78a99a-7a2d-47f5-ab79-0bc5f3254dae', E'6cad8663-d0e1-4068-9759-8c8aaedb4af6', E'Сахарным диабетом без поражения печени.', E'0'),
  (E'f1e24ea7-f3b1-4428-a852-201025cfd012', E'6cad8663-d0e1-4068-9759-8c8aaedb4af6', E'Алкогольным гепатитом.', E'1'),
  (E'1acfab48-de35-477d-9ce2-93e2a3983fd9', E'6cad8663-d0e1-4068-9759-8c8aaedb4af6', E'Исключительно с инфарктом печени.', E'2'),
  (E'db634c66-cc00-43ca-8623-23c63fbefa80', E'6cad8663-d0e1-4068-9759-8c8aaedb4af6', E'Отложением кальция в гепатоцитах.', E'3'),
  (E'6591c4a8-ff49-463e-8288-b3e2c09f4768', E'73fb80e6-f5bc-475b-88df-beec0eaab466', E'Она определяется накоплением нейтрального жира и выявляется Суданом III.', E'0'),
  (E'402e51c3-c4c6-43af-945e-a0f2e83697a4', E'73fb80e6-f5bc-475b-88df-beec0eaab466', E'В цитоплазме появляются вакуоли вследствие нарушения водно-электролитного обмена клетки.', E'1'),
  (E'2cebb213-8273-479b-a8be-b3ffb2f2ec4a', E'73fb80e6-f5bc-475b-88df-beec0eaab466', E'Она ограничена только стромой органов.', E'2'),
  (E'7e7d7edc-301a-46a7-9a27-21f0a6387048', E'73fb80e6-f5bc-475b-88df-beec0eaab466', E'Она всегда не влияет на функцию клетки.', E'3'),
  (E'5fefda05-6c74-4c0e-9607-ef42fa36dbb8', E'3747c271-34e2-45d6-b17f-2f632a551caf', E'Только полное восстановление структуры.', E'0'),
  (E'f0d39b30-7752-45ae-98c9-6c642ae98942', E'3747c271-34e2-45d6-b17f-2f632a551caf', E'Обязательное формирование амилоида.', E'1'),
  (E'd1bfa73a-22b9-4aa1-bdd3-b0b2c293de27', E'3747c271-34e2-45d6-b17f-2f632a551caf', E'Баллонная дистрофия и колликвационный некроз клетки.', E'2'),
  (E'cf3f31a7-1818-481d-9f95-c57f0420418e', E'3747c271-34e2-45d6-b17f-2f632a551caf', E'Развитие исключительно гиперкератоза.', E'3'),
  (E'955bf65b-1c31-425c-bc8a-464822d594b3', E'23d9a0da-077c-4473-94a6-498563bb8648', E'При неосложнённой гипертонической болезни.', E'0'),
  (E'40f02761-7705-4905-ba50-73f55b4fda00', E'23d9a0da-077c-4473-94a6-498563bb8648', E'При вирусном гепатите.', E'1'),
  (E'90b0d82c-fba6-4c13-a8cb-53075f9779fa', E'23d9a0da-077c-4473-94a6-498563bb8648', E'При изолированном атеросклерозе аорты.', E'2'),
  (E'2140e549-a793-482d-a37d-61485f2753b9', E'23d9a0da-077c-4473-94a6-498563bb8648', E'При переломе кости.', E'3'),
  (E'30f27006-c709-48ac-8fe7-dfde5be445d1', E'28ce84b0-e67a-43aa-b044-346551156287', E'Накопление триглицеридов в кардиомиоцитах.', E'0'),
  (E'e9af6e25-2c08-40b3-9e3e-e5c70eb3af16', E'28ce84b0-e67a-43aa-b044-346551156287', E'Накопление белковых капель в эпителии канальцев.', E'1'),
  (E'8130f7c9-ae6d-41e6-8f07-d69aed40e473', E'28ce84b0-e67a-43aa-b044-346551156287', E'Избыточное образование рогового вещества в ороговевающем эпителии либо патологическое ороговение там, где его обычно нет.', E'2'),
  (E'727cb175-3586-40ab-bdd1-651c82db83c2', E'28ce84b0-e67a-43aa-b044-346551156287', E'Отложение солей кальция в некротизированной ткани.', E'3'),
  (E'5eff4f38-aa2d-4a5b-9e9f-22e139931422', E'2e2a902e-9d14-4769-9cde-75ae1a45f2d0', E'Гидропическая дистрофия — лейкоплакия.', E'0'),
  (E'a35a13eb-4599-482b-aaf8-e8d129793be1', E'2e2a902e-9d14-4769-9cde-75ae1a45f2d0', E'Патологическое ороговение слизистой оболочки — лейкоплакия.', E'1'),
  (E'6340d9ea-d742-43ca-bdec-5e8588eeabb8', E'2e2a902e-9d14-4769-9cde-75ae1a45f2d0', E'Жировая дистрофия — ихтиоз.', E'2'),
  (E'835276e3-27ab-408f-83de-3fcc1ae4840b', E'2e2a902e-9d14-4769-9cde-75ae1a45f2d0', E'Гиалиново-капельная дистрофия — «тигровое сердце».', E'3'),
  (E'c562cd78-414d-4232-85e5-2d2ef0babd2a', E'565e6acc-a394-41b7-88eb-22d04203af0e', E'Она всегда приводит к немедленному некрозу всей слизистой.', E'0'),
  (E'1fda5063-daaa-48ea-aafa-5df262b8b70c', E'565e6acc-a394-41b7-88eb-22d04203af0e', E'Она является разновидностью жирового липидоза.', E'1'),
  (E'61702e0d-90c9-402c-98fe-a12482e5649b', E'565e6acc-a394-41b7-88eb-22d04203af0e', E'Она рассматривается как возможный источник развития злокачественной опухоли.', E'2'),
  (E'094adede-e4a1-46b5-8741-290fbf352e7b', E'565e6acc-a394-41b7-88eb-22d04203af0e', E'Она всегда наследуется.', E'3'),
  (E'fbcd68bc-fb75-43a1-89b1-e219fcce6ec5', E'2feb4438-9993-4275-b215-2f668234aa1a', E'Недостаточное образование гликогена в печени.', E'0'),
  (E'9385ae2b-87f9-4e2d-9087-08f81dc7c1a5', E'2feb4438-9993-4275-b215-2f668234aa1a', E'Избыточное образование рогового вещества; тяжёлый врождённый ихтиоз может быть несовместим с жизнью.', E'1'),
  (E'4f0f51b0-ae96-45e5-9130-2fd1c30b0da8', E'2feb4438-9993-4275-b215-2f668234aa1a', E'Накопление жира в миокарде.', E'2'),
  (E'8ce835a8-fe4e-4efd-9e99-36cf12192f40', E'2feb4438-9993-4275-b215-2f668234aa1a', E'Отложение гиалина в сосудах.', E'3'),
  (E'81487396-7489-4162-9b73-d66bdae54807', E'565fc072-c314-493e-be35-44f815112ea2', E'Окраску гематоксилином и эозином на всех фиксированных парафиновых срезах как единственный метод.', E'0'),
  (E'1c643fcb-4505-42dd-9311-d9d069598380', E'565fc072-c314-493e-be35-44f815112ea2', E'Окраску Суданом III замороженных срезов.', E'1'),
  (E'fd088c0e-0a07-4a86-b8ab-6d5be5f8cb0d', E'565fc072-c314-493e-be35-44f815112ea2', E'Реакцию Перлса.', E'2'),
  (E'a6f18c0c-a1ee-455d-a5fc-f533d80425ba', E'565fc072-c314-493e-be35-44f815112ea2', E'Метахромазию толуидиновым синим.', E'3'),
  (E'2a98fe7f-f596-45e4-872b-d71ddbc9e38f', E'9cf4ef72-6718-4de8-8272-11b9f08f0cdb', E'Потому что жир окрашивается в ярко-синий цвет.', E'0'),
  (E'ddcd3b12-4c13-4afe-a15b-843da26ada63', E'9cf4ef72-6718-4de8-8272-11b9f08f0cdb', E'Капли жира растворяются при обработке спиртами и ксилолом, оставляя пустоты.', E'1'),
  (E'652975de-e7a4-4cf9-81e9-bc7941183aba', E'9cf4ef72-6718-4de8-8272-11b9f08f0cdb', E'Потому что липиды превращаются в кальций.', E'2'),
  (E'dfddc1de-1c3a-4b65-9d0c-ab1a2f5bc1b4', E'9cf4ef72-6718-4de8-8272-11b9f08f0cdb', E'Потому что ядра клеток полностью исчезают при фиксации.', E'3'),
  (E'26d324d7-b448-41b9-989c-04d9528c6fdb', E'f6dd8320-e2a2-488e-afac-39b4a1fefb51', E'Уменьшенная, плотная, чёрная на разрезе.', E'0'),
  (E'7daac1cb-91ba-4138-b56b-4b6abf2858bd', E'f6dd8320-e2a2-488e-afac-39b4a1fefb51', E'Увеличенная, дряблая, жёлтая на разрезе.', E'1'),
  (E'1ce05272-bf8d-40bb-a7f3-24da7d90f174', E'f6dd8320-e2a2-488e-afac-39b4a1fefb51', E'Мелкая, бугристая и обязательно с множественными рубцами.', E'2'),
  (E'19d036e2-8392-4619-9629-2666ae013874', E'f6dd8320-e2a2-488e-afac-39b4a1fefb51', E'Без каких-либо возможных изменений размера и консистенции.', E'3'),
  (E'1b813050-1e93-4d69-a679-1e538cbd7009', E'6ecdd62b-b2ea-49da-9926-e08e6caa0777', E'Избыточное поступление жирных кислот и триглицеридов.', E'0'),
  (E'a3dc7f63-4eff-4db8-849e-e8b6244073a8', E'6ecdd62b-b2ea-49da-9926-e08e6caa0777', E'Снижение окисления жирных кислот при гипоксии.', E'1');
INSERT INTO public.question_options (id, question_id, option_text, sort_order) VALUES
  (E'b53aeb1c-49a6-4fda-9743-f95fe9295461', E'6ecdd62b-b2ea-49da-9926-e08e6caa0777', E'Снижение выведения липидов из-за уменьшения продукции апопротеина.', E'2'),
  (E'ceffd664-435f-46de-a0d5-41cb7f5ec171', E'6ecdd62b-b2ea-49da-9926-e08e6caa0777', E'Усиленное выведение липидов из клетки как причина их накопления.', E'3'),
  (E'5b221a68-9b8b-46ba-ae9a-dcd8d2b6cd71', E'607a3ec4-af76-41b1-bd56-180f3eaaaaa5', E'Только декомпозицию при нарастающей гипоксии.', E'0'),
  (E'6858162c-f9a3-46dd-a1ac-8599271f8fa7', E'607a3ec4-af76-41b1-bd56-180f3eaaaaa5', E'Инфильтрационный механизм, характерный для гиперлипидемии.', E'1'),
  (E'f95f665e-4e42-443d-92ea-3e594c15e497', E'607a3ec4-af76-41b1-bd56-180f3eaaaaa5', E'Обязательный некроз всех гепатоцитов.', E'2'),
  (E'912f3cb7-a4e2-4ec9-909e-38ac9f1f1ab6', E'607a3ec4-af76-41b1-bd56-180f3eaaaaa5', E'Преимущественно стромальную дистрофию.', E'3'),
  (E'ae93e329-f1b5-4747-9469-db109fc2aeed', E'3edd286e-256e-407f-8503-45a581a47503', E'Плотный миокард с равномерным чёрным окрашиванием.', E'0'),
  (E'9c081f58-ad51-486c-89cc-8e3cf7a54624', E'3edd286e-256e-407f-8503-45a581a47503', E'Дряблый, бледно-жёлтый миокард; желтовато-белая исчерченность под эндокардом — «тигровое сердце».', E'1'),
  (E'92da865e-6cda-4dca-bd80-bbead1ec2797', E'3edd286e-256e-407f-8503-45a581a47503', E'Утолщение клапанов с образованием белых бляшек.', E'2'),
  (E'8bdde54f-e753-4e5a-8efe-54f6630a661b', E'3edd286e-256e-407f-8503-45a581a47503', E'Увеличение числа кардиомиоцитов без изменения цитоплазмы.', E'3'),
  (E'd1aa4ea2-987b-4cc6-b661-15b7882ac255', E'1598e104-344b-4c98-864d-c980323c9da8', E'Гиперкератоз.', E'0'),
  (E'32af7837-1886-43f4-a589-ab5484bc0fe9', E'1598e104-344b-4c98-864d-c980323c9da8', E'Гипоксия, например при анемии или хронической сердечно-сосудистой недостаточности.', E'1'),
  (E'd856d818-777c-4979-866c-9c91a40ac8c9', E'1598e104-344b-4c98-864d-c980323c9da8', E'Изолированная гиперкальциемия.', E'2'),
  (E'e9d5d60b-a72e-40a0-814e-438a20750612', E'1598e104-344b-4c98-864d-c980323c9da8', E'Избыточное образование рогового вещества.', E'3'),
  (E'd847cb0e-c884-4805-9b3a-7f014c97c80f', E'5f1aeae5-f81d-4545-b7b3-88d57c32ab2d', E'Она всегда необратима и немедленно приводит к циррозу.', E'0'),
  (E'2ac14d56-cb68-4293-af65-ce6cc81d2fde', E'5f1aeae5-f81d-4545-b7b3-88d57c32ab2d', E'Процесс может быть обратимым, а функция печени длительное время может оставаться сохранной.', E'1'),
  (E'a9ae6e69-dc5b-4f09-80f1-52a8ee023850', E'5f1aeae5-f81d-4545-b7b3-88d57c32ab2d', E'Обязательное развитие колликвационного некроза.', E'2'),
  (E'21e5b07a-6faa-4dd7-9d12-0a8a709acd36', E'5f1aeae5-f81d-4545-b7b3-88d57c32ab2d', E'Всегда формируется опухоль.', E'3'),
  (E'4ea3de0a-447d-4a49-9da8-c7c540514cdb', E'1158ed83-d7e2-49c3-8ddf-19e7a8eb9058', E'Массивное накопление кальция в ядрах.', E'0'),
  (E'531c8189-4dcd-4205-8a36-cc597d9d31d2', E'1158ed83-d7e2-49c3-8ddf-19e7a8eb9058', E'Светлые, «дырчатые» или «пустые» ядра гепатоцитов вследствие включений гликогена; запасы гликогена в печени уменьшаются.', E'1'),
  (E'e2501f54-d893-442a-b7b3-fe907f18e079', E'1158ed83-d7e2-49c3-8ddf-19e7a8eb9058', E'Образование телец Мэллори во всех случаях.', E'2'),
  (E'e65cf1d2-7072-4fe5-a7bd-e71bc3883698', E'1158ed83-d7e2-49c3-8ddf-19e7a8eb9058', E'Преимущественно ороговение гепатоцитов.', E'3'),
  (E'49f2abe2-4566-4505-9580-b8ab53368cca', E'6a34858d-46d6-4feb-a7e1-3074ca386944', E'Только накопление нейтрального жира в клубочках.', E'0'),
  (E'f4a5b045-52bd-4aa2-828a-5cebb68265a1', E'6a34858d-46d6-4feb-a7e1-3074ca386944', E'Гликогенная инфильтрация эпителия канальцев, особенно узкого и дистального сегментов; цитоплазма становится светлой и пенистой.', E'1'),
  (E'0d9a2303-fa46-4931-a0b5-3dc7319abcae', E'6a34858d-46d6-4feb-a7e1-3074ca386944', E'Ороговение эпителия канальцев.', E'2'),
  (E'aeef23d8-6810-44e1-bc2f-8d367795c27e', E'6a34858d-46d6-4feb-a7e1-3074ca386944', E'Полное отсутствие изменений при глюкозурии.', E'3'),
  (E'b56a28fd-f136-4ffe-84d5-dc8b40c7feca', E'68e51e1b-702e-4588-b7df-772ddb2d464f', E'Мукоидное набухание.', E'0'),
  (E'735b2eb3-10ad-4f33-9f17-150e86e24353', E'68e51e1b-702e-4588-b7df-772ddb2d464f', E'Тельца Каунсильмена.', E'1'),
  (E'1f693593-ee72-4954-b7c8-a4c63130927c', E'68e51e1b-702e-4588-b7df-772ddb2d464f', E'Интеркапиллярный (диабетический) гломерулосклероз.', E'2'),
  (E'00fe899e-2493-43ba-a9e5-e384ce585c71', E'68e51e1b-702e-4588-b7df-772ddb2d464f', E'Лейкоплакия.', E'3'),
  (E'a737fd5e-7bdf-415a-a73b-a8d7f1262a7a', E'8b9c9ac9-2217-4100-87df-861848f203de', E'Приобретённые воспалительные заболевания слизистой оболочки.', E'0'),
  (E'49040213-60ad-47d9-b4f9-ffad02a1bc80', E'8b9c9ac9-2217-4100-87df-861848f203de', E'Наследственные углеводные дистрофии, связанные с нарушениями обмена гликогена.', E'1'),
  (E'9a812cf5-2f89-4f20-a354-f694526a2b10', E'8b9c9ac9-2217-4100-87df-861848f203de', E'Разновидность жировой дистрофии миокарда.', E'2'),
  (E'50e17954-153c-47d8-92b8-8a86fed1049c', E'8b9c9ac9-2217-4100-87df-861848f203de', E'Обязательная стадия лейкоплакии.', E'3'),
  (E'd73aaeb9-7f9a-431b-992c-382c2e6160fa', E'bbdcdd6f-1b21-4b96-8f12-0cc0a129accd', E'Они развиваются исключительно в межклеточном веществе соединительной ткани.', E'0'),
  (E'23c9377f-c599-48ea-943b-426643d67ad5', E'bbdcdd6f-1b21-4b96-8f12-0cc0a129accd', E'Они связаны с нарушением обмена высокоспециализированных клеток паренхиматозных органов, например сердца, печени и почек.', E'1'),
  (E'5162054d-5c81-46c2-910b-200ec7127d48', E'bbdcdd6f-1b21-4b96-8f12-0cc0a129accd', E'Они не относятся к повреждению.', E'2'),
  (E'33dd3a9e-ac31-40be-b0b9-5645278163bb', E'bbdcdd6f-1b21-4b96-8f12-0cc0a129accd', E'Они всегда являются наследственными.', E'3'),
  (E'e05d898d-2291-499f-9de1-d3717171cc13', E'4fc7082f-3ac6-4f7c-94af-da5c21cfc181', E'Дистрофии могут быть местными или системными.', E'0'),
  (E'd5bb92a9-d33c-4ea3-b52f-062a18060751', E'4fc7082f-3ac6-4f7c-94af-da5c21cfc181', E'По происхождению дистрофии бывают приобретёнными и наследственными.', E'1'),
  (E'8a1b7a90-012f-43f2-b8e1-8f8aa6dfad75', E'4fc7082f-3ac6-4f7c-94af-da5c21cfc181', E'Любая дистрофия обязательно начинается с воспаления и заканчивается образованием опухоли.', E'2'),
  (E'355837b4-2663-4fa6-afa6-7e5237956428', E'4fc7082f-3ac6-4f7c-94af-da5c21cfc181', E'По локализации выделяют паренхиматозные, стромально-сосудистые и смешанные дистрофии.', E'3'),
  (E'c5fb76ad-dc5a-4048-82be-536d851e0de5', E'39186242-e6ca-4219-b0ea-9270624810d8', E'Они всегда представляют только косметическое изменение органа.', E'0'),
  (E'308754bc-8f63-4d52-9ab3-edf9810fdbcc', E'39186242-e6ca-4219-b0ea-9270624810d8', E'Они отражают повреждение клеточного обмена; при прогрессировании могут нарушать функцию и приводить к гибели клеток.', E'1'),
  (E'faa04a70-77ea-4326-8bac-498f918d5ca2', E'39186242-e6ca-4219-b0ea-9270624810d8', E'Они не имеют морфологических проявлений.', E'2'),
  (E'506403fd-7d72-4ae3-998a-83de4abb57ee', E'39186242-e6ca-4219-b0ea-9270624810d8', E'Их исход всегда благоприятный независимо от тяжести.', E'3'),
  (E'6da4d991-d793-4feb-b628-51c1bc648cfe', E'9ebc5e2c-4920-40a0-b7d3-ab16e505dfcb', E'Распада ультраструктур клетки без поступления веществ извне.', E'0'),
  (E'28c475a3-183e-4249-bf31-3c9de0254553', E'9ebc5e2c-4920-40a0-b7d3-ab16e505dfcb', E'Избыточного поступления и накопления продуктов обмена из крови и лимфы в клетках или межклеточном веществе.', E'1'),
  (E'15993e21-5016-4130-86be-f4bad86f3a04', E'9ebc5e2c-4920-40a0-b7d3-ab16e505dfcb', E'Образования веществ, не встречающихся в норме, только за счёт синтеза.', E'2'),
  (E'947cba16-ba56-4739-be2d-f887a205a251', E'9ebc5e2c-4920-40a0-b7d3-ab16e505dfcb', E'Замещения паренхимы соединительной тканью.', E'3'),
  (E'a02a9e98-3e90-4c9a-a36b-af401a6b622e', E'e02e7800-5760-44b2-a0dd-19dd7489dae0', E'Посмертное свертывание крови', E'0'),
  (E'7bbf4acb-33c4-4609-9805-7fec67be6702', E'e02e7800-5760-44b2-a0dd-19dd7489dae0', E'Прижизненное образование тромба в сосуде или полости сердца', E'1'),
  (E'acc2000e-3872-4899-a117-109a19f8ffc3', E'e02e7800-5760-44b2-a0dd-19dd7489dae0', E'Выход крови в ткани', E'2'),
  (E'a2b05f68-7905-4b32-bae4-9fb722d3f107', E'e02e7800-5760-44b2-a0dd-19dd7489dae0', E'Закупорка сосуда воздухом', E'3'),
  (E'c4babb61-c4da-4658-86d5-ba3a03a819f6', E'e0497c9e-f824-4ac6-8ba8-4fcffd7431a3', E'Гиперкоагуляция', E'0'),
  (E'af408a8b-e7ca-4c5b-9545-9c27369f3aaa', E'e0497c9e-f824-4ac6-8ba8-4fcffd7431a3', E'Изолированное потоотделение', E'1'),
  (E'bbc9d6ad-0ed2-4490-83cb-3843c294c570', E'e0497c9e-f824-4ac6-8ba8-4fcffd7431a3', E'Полное подавление тромбоцитов', E'2'),
  (E'4837e20a-6fe8-43d0-a20f-b99684e3ccf1', E'e0497c9e-f824-4ac6-8ba8-4fcffd7431a3', E'Увеличение просвета сосудов', E'3'),
  (E'0556c3c7-71a8-4a4d-a54b-e6c8b35cdd4c', E'c36acc4d-7f52-4739-913f-ddd3ce0ba647', E'Прикрепление к стенке и возможная слоистость', E'0'),
  (E'5b40db14-6d1e-4409-96de-082b66f16b0b', E'c36acc4d-7f52-4739-913f-ddd3ce0ba647', E'Полное отсутствие фибрина', E'1'),
  (E'a54eaafc-37c5-41c6-854c-01e9396fc428', E'c36acc4d-7f52-4739-913f-ddd3ce0ba647', E'Обязательное наличие жира', E'2'),
  (E'4477eb75-b137-4487-bf71-e4730448305e', E'c36acc4d-7f52-4739-913f-ddd3ce0ba647', E'Расположение вне сосудов', E'3'),
  (E'6f842f31-fe8f-4342-a6e9-29bc0cb1eb21', E'fbff107e-827e-4b0a-ba88-706157f62887', E'Реканализацией', E'0'),
  (E'cba50415-f10f-43c1-b2e4-2c608c0b9c89', E'fbff107e-827e-4b0a-ba88-706157f62887', E'Тромбоэмболией', E'1'),
  (E'dc9e320e-4dec-4520-a41c-b904d0f128b9', E'fbff107e-827e-4b0a-ba88-706157f62887', E'Септическим распадом', E'2'),
  (E'f13108c0-e640-444d-bcdb-6eefa1e39163', E'fbff107e-827e-4b0a-ba88-706157f62887', E'Кровоизлиянием', E'3'),
  (E'a4090ada-1f90-4d56-b6a4-a295a6dfa0fc', E'cbb8c66c-c6be-4358-88a2-b0f62786df4a', E'Распространением инфекции и септическими эмболами', E'0'),
  (E'cc7ca405-f3aa-406e-b12c-b7f2fbeb78fe', E'cbb8c66c-c6be-4358-88a2-b0f62786df4a', E'Обязательным восстановлением просвета', E'1'),
  (E'ee5cdc3a-0c04-4f11-a06d-dab7a214aa98', E'cbb8c66c-c6be-4358-88a2-b0f62786df4a', E'Повышением альбумина', E'2'),
  (E'17c37e09-31c2-4dc6-ae5c-3d1e9abaa473', E'cbb8c66c-c6be-4358-88a2-b0f62786df4a', E'Превращением в лимфатический узел', E'3'),
  (E'5aee663a-2ad4-4e52-94c1-2ae01baaa3c6', E'b7512588-538c-4fd0-98d5-5b9f2497288c', E'Движется против обычного кровотока', E'0'),
  (E'5350ed5d-4d4b-406d-b911-add0a3c77be2', E'b7512588-538c-4fd0-98d5-5b9f2497288c', E'Движется строго по току крови', E'1'),
  (E'569405f0-cda6-434e-b3da-6abebada448b', E'b7512588-538c-4fd0-98d5-5b9f2497288c', E'Растворяется без перемещения', E'2'),
  (E'911b8c95-aac7-432e-870e-1c2cf6c4ec13', E'b7512588-538c-4fd0-98d5-5b9f2497288c', E'Выходит вместе с плазмой в ткань', E'3'),
  (E'89f05e47-00c6-4d51-b981-258f27e60469', E'30811497-d642-4191-9e9d-6d128f95330c', E'Травма костей, дыхательные и неврологические нарушения, петехии', E'0'),
  (E'64a0019f-3d8b-4fca-8c1a-7e4023afab20', E'30811497-d642-4191-9e9d-6d128f95330c', E'Только хронический кашель', E'1'),
  (E'8f52e112-5bd8-41e0-85d0-7aad6e990c56', E'30811497-d642-4191-9e9d-6d128f95330c', E'Изолированное увеличение печени', E'2'),
  (E'fc4e40a3-d4f6-488b-9b1a-93ee541f92ed', E'30811497-d642-4191-9e9d-6d128f95330c', E'Амилоидоз почек', E'3'),
  (E'0478448b-84d1-4e00-9b9a-f96834f74d00', E'a3c12f47-a8ba-4147-883a-29a093272ecb', E'Перенос микроорганизмов или инфицированных частиц кровью', E'0'),
  (E'df8325b4-1a0e-49aa-9a37-52a8d2d2d031', E'a3c12f47-a8ba-4147-883a-29a093272ecb', E'Закупорка только жиром', E'1'),
  (E'8f101e2b-8812-4a09-9b91-318e3c82a527', E'a3c12f47-a8ba-4147-883a-29a093272ecb', E'Отложение холестерина в стенке артерии', E'2'),
  (E'79c82c6f-778f-4ab3-aa67-06fa43492032', E'a3c12f47-a8ba-4147-883a-29a093272ecb', E'Выход плазмы', E'3'),
  (E'a317ff7a-4889-4bd7-9983-259d81179cde', E'dfd5b93f-110b-4888-a7a7-a584e0ec6d6d', E'Глубокие вены ног и таза', E'0'),
  (E'738dd41e-fb43-4970-898e-c54f65cbe9ca', E'dfd5b93f-110b-4888-a7a7-a584e0ec6d6d', E'Лимфатические сосуды кожи', E'1'),
  (E'74ca8e02-b75e-45b5-8e01-41dfb9b416b6', E'dfd5b93f-110b-4888-a7a7-a584e0ec6d6d', E'Кальцифицированные узлы щитовидной железы', E'2'),
  (E'91852d16-aba7-440c-81db-318daeb5e2ad', E'dfd5b93f-110b-4888-a7a7-a584e0ec6d6d', E'Подкожные кровоизлияния', E'3'),
  (E'5189a65d-3251-4558-9057-482bfaed93b8', E'6614b0e2-6f6c-4f67-abc2-5571a009c41b', E'Острое расширение правого желудочка', E'0'),
  (E'91d4bdd9-3fa7-4762-bd78-87596df090d6', E'6614b0e2-6f6c-4f67-abc2-5571a009c41b', E'Обязательная гипертрофия левого желудочка', E'1'),
  (E'ce9ad9e4-b002-42a2-8956-6d2d9f0984f9', E'6614b0e2-6f6c-4f67-abc2-5571a009c41b', E'Амилоидоз миокарда как прямое следствие', E'2'),
  (E'036aaa21-d116-4f22-a499-dc86777ae662', E'6614b0e2-6f6c-4f67-abc2-5571a009c41b', E'Отсутствие изменений при любой тяжести', E'3'),
  (E'001ce029-4101-4cda-bb10-322c2a5487a2', E'bdd58325-ea1a-4196-8521-4d5310f3826f', E'Клиновидному ишемическому инфаркту почки', E'0'),
  (E'43a67ea4-d4c3-4901-8848-9134d7fec56a', E'bdd58325-ea1a-4196-8521-4d5310f3826f', E'Венозному полнокровию всех органов', E'1'),
  (E'4774434f-b89d-4265-aa3b-75482d782640', E'bdd58325-ea1a-4196-8521-4d5310f3826f', E'Обязательной жировой дистрофии печени', E'2'),
  (E'1d052ec3-7276-4930-844e-91775b66612c', E'bdd58325-ea1a-4196-8521-4d5310f3826f', E'Полному сохранению ткани без притока крови', E'3'),
  (E'85bc3680-f836-405f-8175-fdd830a6edd0', E'21b90020-3fe5-4635-992a-ddbb2ba5d124', E'Обтурационную', E'0'),
  (E'5806e729-fb04-42eb-99db-d4eced1f1538', E'21b90020-3fe5-4635-992a-ddbb2ba5d124', E'Ангиоспастическую', E'1'),
  (E'ceaea2fd-ae8a-4aec-b054-0c4cf5da59e0', E'21b90020-3fe5-4635-992a-ddbb2ba5d124', E'Венозную гиперемию', E'2'),
  (E'd2c42c39-6240-48e8-85a1-861250ae7716', E'21b90020-3fe5-4635-992a-ddbb2ba5d124', E'Геморрагическую инфильтрацию', E'3'),
  (E'6275d786-89c9-4fbb-8da0-b1646baaf709', E'3f171061-872a-414d-9fc7-f58a5eb226cd', E'компенсаторная гиперплазия с пролиферацией сохранившихся гепатоцитов', E'0'),
  (E'dcc282c3-4ce6-425f-b074-d892a6b9e187', E'3f171061-872a-414d-9fc7-f58a5eb226cd', E'изолированная гипертрофия без увеличения числа гепатоцитов', E'1');
INSERT INTO public.question_options (id, question_id, option_text, sort_order) VALUES
  (E'd8f96e74-8a01-495c-9ff5-c09466f71c53', E'3f171061-872a-414d-9fc7-f58a5eb226cd', E'организация некротического очага с формированием коллагенового рубца', E'2'),
  (E'412ffe5a-d469-4d5e-97fe-664e0f39ccdb', E'3f171061-872a-414d-9fc7-f58a5eb226cd', E'дисфункциональная атрофия вследствие снижения механической нагрузки', E'3'),
  (E'b80745ef-6084-4692-98c9-3edd4a671af4', E'c5bea212-de3a-473b-b2c1-ed0d31fd66e1', E'гипертрофия, гиперплазия, атрофия и метаплазия', E'0'),
  (E'c9a630fa-8109-41be-844e-928cc8d43e08', E'c5bea212-de3a-473b-b2c1-ed0d31fd66e1', E'некроз, апоптоз, тромбоз и эмболия', E'1'),
  (E'ade37e61-493d-4bd1-b8ff-9ade640191c5', E'c5bea212-de3a-473b-b2c1-ed0d31fd66e1', E'организация, реканализация, тромбоэмболия и инфаркт', E'2'),
  (E'de63688c-74b9-4538-9c4a-f981b781a8f4', E'c5bea212-de3a-473b-b2c1-ed0d31fd66e1', E'экссудация, кровоизлияние, кальциноз и гиалиноз', E'3'),
  (E'7f347672-c816-4a3c-a138-e6799d5a5c1c', E'aa662832-6cea-4642-9fbb-a210f1a00a89', E'Повреждение эндотелия, нарушение кровотока и гиперкоагуляцию', E'0'),
  (E'3c3067f2-0474-4907-8ced-c5b76cc953e5', E'aa662832-6cea-4642-9fbb-a210f1a00a89', E'Гипотермию, гипогликемию и лихорадку', E'1'),
  (E'2d8c01fc-217e-4beb-8d92-4607341981aa', E'aa662832-6cea-4642-9fbb-a210f1a00a89', E'Усиление лимфооттока и расширение артериол', E'2'),
  (E'16b7e173-7738-4d72-978c-19dacd583d05', E'aa662832-6cea-4642-9fbb-a210f1a00a89', E'Только снижение числа эритроцитов', E'3'),
  (E'48efb20e-2b6d-4017-b26e-bed0ca809aaa', E'cd9dc367-e6cf-4135-8882-6e3c807954a2', E'Белый, богатый тромбоцитами и фибрином', E'0'),
  (E'54bc9579-075f-4a28-87fb-365c90fad746', E'cd9dc367-e6cf-4135-8882-6e3c807954a2', E'Красный, богатый эритроцитами', E'1'),
  (E'dbb8addf-2684-4e3e-a8db-55c0adb8892d', E'cd9dc367-e6cf-4135-8882-6e3c807954a2', E'Посмертный сгусток', E'2'),
  (E'eb54bdb0-7ea5-4a64-ae87-c1fb92a5146f', E'cd9dc367-e6cf-4135-8882-6e3c807954a2', E'Воздушный пузырёк', E'3'),
  (E'ef3ec8ed-cd91-4900-b04b-66e10b1045b8', E'1f31428c-d883-4f63-9cc7-ea80eb2154ec', E'Полностью закрывает просвет', E'0'),
  (E'da4ae499-c1fc-4005-ab87-c7bcd34766d6', E'1f31428c-d883-4f63-9cc7-ea80eb2154ec', E'Прикреплён к стенке, но не закрывает весь просвет', E'1'),
  (E'3299d083-81a7-42c7-b959-7cedffab665f', E'1f31428c-d883-4f63-9cc7-ea80eb2154ec', E'Образуется только после смерти', E'2'),
  (E'af1d9def-fcb4-40bb-a45f-daa251cc2462', E'1f31428c-d883-4f63-9cc7-ea80eb2154ec', E'Находится только в лимфатическом узле', E'3'),
  (E'd7912aa3-6fc2-454e-a2a4-a39d068b36e5', E'f0da8d90-37b8-42b7-a0c3-108bfe574580', E'Отложение солей кальция', E'0'),
  (E'572d0530-a3b0-4d87-86f9-8e62246fcad8', E'f0da8d90-37b8-42b7-a0c3-108bfe574580', E'Прорастание новыми сосудами', E'1'),
  (E'ceb56fe0-5add-4d8e-9417-b8daf15121da', E'f0da8d90-37b8-42b7-a0c3-108bfe574580', E'Полное растворение', E'2'),
  (E'24b3ecb9-3917-4159-9686-c1d6bd2a06d6', E'f0da8d90-37b8-42b7-a0c3-108bfe574580', E'Превращение в газ', E'3'),
  (E'0704caab-da3a-4340-a1b7-4b1b752323d8', E'f0e50622-bf6b-48fb-9c00-29f8fc4ae035', E'Образование тромба на месте закупорки', E'0'),
  (E'ac5356ff-6b33-4160-9f42-3a58cd2f9185', E'f0e50622-bf6b-48fb-9c00-29f8fc4ae035', E'Перенос кровью частиц с закупоркой сосуда в другом участке', E'1'),
  (E'742a58d5-476d-49df-9189-c666cee4e779', E'f0e50622-bf6b-48fb-9c00-29f8fc4ae035', E'Выход плазмы в ткань', E'2'),
  (E'81c09b51-4986-41c4-9a4b-d05efab0fb3a', E'f0e50622-bf6b-48fb-9c00-29f8fc4ae035', E'Расширение артерии', E'3'),
  (E'b99506e9-1dae-4fb2-b182-7fc668911958', E'a93c1202-230b-469e-9a1b-d9101ec440a8', E'Сообщение между правыми и левыми отделами кровообращения', E'0'),
  (E'075c737d-f42c-4161-8016-4663df84ee50', E'a93c1202-230b-469e-9a1b-d9101ec440a8', E'Закрытие всех лимфатических сосудов', E'1'),
  (E'5fc90573-2e89-4720-88f3-04bd9a31666c', E'a93c1202-230b-469e-9a1b-d9101ec440a8', E'Только артериальный тромб без сообщения', E'2'),
  (E'fe093070-29c6-417d-b9ef-4d403dcf68dc', E'a93c1202-230b-469e-9a1b-d9101ec440a8', E'Повышение онкотического давления', E'3'),
  (E'cf6ef1d3-3f1d-4d41-bb30-ee7307b39933', E'fdf7ffca-2171-4586-af41-1032963e99ea', E'Попадании воздуха в сосуды при повреждении крупных вен или манипуляциях', E'0'),
  (E'c8a99fc7-6ba3-4e38-99a3-63238a5b043c', E'fdf7ffca-2171-4586-af41-1032963e99ea', E'Обычном венозном застое', E'1'),
  (E'e1872eb7-8e19-4019-a23b-90f91aa6f9e4', E'fdf7ffca-2171-4586-af41-1032963e99ea', E'Петрификации тромба', E'2'),
  (E'ad6a2a4d-15b5-4085-a0e8-73eb4d8e7470', E'fdf7ffca-2171-4586-af41-1032963e99ea', E'Гемолизе в селезёнке', E'3'),
  (E'df67aa75-d6fd-408e-8759-e2c209a307b4', E'b17d1c70-7852-40b0-87e9-9ef244482129', E'Фрагментов ткани или опухолевых клеток', E'0'),
  (E'46e72aec-76a9-4b99-a5de-69ff841e1608', E'b17d1c70-7852-40b0-87e9-9ef244482129', E'Растворённого альбумина', E'1'),
  (E'684b7099-f137-4e86-895e-8e5eed28ef44', E'b17d1c70-7852-40b0-87e9-9ef244482129', E'Воздуха', E'2'),
  (E'4227a9e9-6484-45ff-8326-161b4983fa01', E'b17d1c70-7852-40b0-87e9-9ef244482129', E'Нормальных тромбоцитов без агрегатов', E'3'),
  (E'48ba6b16-bc50-406e-b7ba-c27fa417c7f9', E'83f49613-45b3-4d3e-a794-06077996abeb', E'Острую перегрузку и недостаточность правого желудочка', E'0'),
  (E'7526b95c-c10c-457e-a340-88e7464f44d2', E'83f49613-45b3-4d3e-a794-06077996abeb', E'Снижение нагрузки на правый желудочек', E'1'),
  (E'7db8973f-27b1-49bf-9d9b-cb482dad08d9', E'83f49613-45b3-4d3e-a794-06077996abeb', E'Усиление кровотока через закупоренные сосуды', E'2'),
  (E'3c8548c0-c6e8-4f5a-b57c-e19bd0f08599', E'83f49613-45b3-4d3e-a794-06077996abeb', E'Обязательный хронический бронхит', E'3'),
  (E'c0706ba4-6f18-4416-9579-cbdd153101ee', E'8d34ada7-a9a9-4cfd-a4ae-addebe33a183', E'У лёгких двойное кровоснабжение', E'0'),
  (E'908463d6-73ac-4afe-afbb-e52e4100e29e', E'8d34ada7-a9a9-4cfd-a4ae-addebe33a183', E'В лёгком нет капилляров', E'1'),
  (E'c232561f-0b20-45f6-aaa0-62a166fed7c4', E'8d34ada7-a9a9-4cfd-a4ae-addebe33a183', E'В лёгочную артерию не поступает венозная кровь', E'2'),
  (E'4976b72b-2c90-4427-bd5c-d81b3390c4dc', E'8d34ada7-a9a9-4cfd-a4ae-addebe33a183', E'Эмбол всегда растворяется сразу', E'3'),
  (E'3842251c-e813-4dba-9242-28165859d306', E'a31d4950-4f04-4bb4-a905-d6694a14cd0d', E'Недостаточное кровоснабжение ткани относительно её потребностей', E'0'),
  (E'5797f76b-3b32-48bc-aac0-0241377fd584', E'a31d4950-4f04-4bb4-a905-d6694a14cd0d', E'Избыточное венозное полнокровие', E'1'),
  (E'c212adac-7a7a-448a-a8bb-a93f3dd00091', E'a31d4950-4f04-4bb4-a905-d6694a14cd0d', E'Выход крови из сосудов', E'2'),
  (E'ad0558fa-023f-473a-8219-361c95d40730', E'a31d4950-4f04-4bb4-a905-d6694a14cd0d', E'Образование тромба', E'3'),
  (E'62c05926-c829-4bd8-811b-682bd3871d53', E'd68ca4c2-0710-4578-937f-f2d791435499', E'От длительности и степени снижения кровотока, чувствительности ткани и коллатералей', E'0'),
  (E'22061c19-37e3-4aab-8ff2-881ef7f64c34', E'd68ca4c2-0710-4578-937f-f2d791435499', E'Только от цвета кожи', E'1'),
  (E'6f1828ce-8b00-48e0-8621-4d17fe4aa588', E'd68ca4c2-0710-4578-937f-f2d791435499', E'Только от числа лимфатических сосудов', E'2'),
  (E'1a1c53ef-cc51-4336-9228-f1d7b4b9c04d', E'd68ca4c2-0710-4578-937f-f2d791435499', E'От любого отёка', E'3'),
  (E'19643994-fb07-462e-a728-c0a5973fade6', E'dce006bf-13a0-49c7-ae03-0295745daae5', E'накопление коллагена с развитием фиброза/склероза и возможной деформацией органа', E'0'),
  (E'ba72b507-e18f-4dd9-a10e-f9c5a39bb49f', E'dce006bf-13a0-49c7-ae03-0295745daae5', E'полная реституция независимо от длительности и объёма повреждения', E'1'),
  (E'1998b064-d264-48aa-b439-4ad600e6833d', E'dce006bf-13a0-49c7-ae03-0295745daae5', E'обязательное увеличение объёма за счёт жира при сохранной паренхиме', E'2'),
  (E'e47737ea-4f2f-4bf6-9a61-a0191cd086a9', E'dce006bf-13a0-49c7-ae03-0295745daae5', E'немедленное исчезновение фибробластов после первого синтеза матрикса', E'3'),
  (E'11c6f663-67be-4221-9c99-f8a8a5c6f1ae', E'806f8df1-e29a-4a7a-add3-21468cc9bbee', E'Разрыв атеросклеротической бляшки', E'0'),
  (E'0b174138-6b28-47d0-a129-bd735cbc41db', E'806f8df1-e29a-4a7a-add3-21468cc9bbee', E'Неповреждённый эндотелий', E'1'),
  (E'97b04557-4044-43ad-b889-c83a72d1daa8', E'806f8df1-e29a-4a7a-add3-21468cc9bbee', E'Усиление лимфодренажа', E'2'),
  (E'd4491670-b9be-4e37-bae6-54de3a7a89f9', E'806f8df1-e29a-4a7a-add3-21468cc9bbee', E'Снижение фибриногена', E'3'),
  (E'2ab80e1c-7aec-4a8a-947c-7441787f12fe', E'c3fef176-1576-45bf-98be-9d21b59b0917', E'Белый', E'0'),
  (E'ab71d49a-a9aa-4c67-a75d-c296f71b2c4c', E'c3fef176-1576-45bf-98be-9d21b59b0917', E'Красный, богатый эритроцитами и фибрином', E'1'),
  (E'63d03368-0c55-4e28-9758-061021d3c5af', E'c3fef176-1576-45bf-98be-9d21b59b0917', E'Состоящий только из кальция', E'2'),
  (E'162541e1-c32c-481d-907f-89b46475eb6c', E'c3fef176-1576-45bf-98be-9d21b59b0917', E'Воздушный', E'3'),
  (E'966c4570-832e-436c-b6fb-29063dcd89e4', E'2c3f5433-1a22-424d-9968-3fc735e23754', E'Воспалительную жидкость с большим количеством белка и клеток', E'0'),
  (E'196c69fd-ded5-4a08-8d20-bb371ce35da2', E'2c3f5433-1a22-424d-9968-3fc735e23754', E'Кровь, вышедшую из сосуда в ткань', E'1'),
  (E'7e2da546-b544-40d0-b69c-27423c8c1631', E'2c3f5433-1a22-424d-9968-3fc735e23754', E'Лимфу с высоким содержанием жира', E'2'),
  (E'e5852a36-8433-4b81-8f3f-5c5ffbdf22ff', E'2c3f5433-1a22-424d-9968-3fc735e23754', E'Невоспалительную жидкость, возникающую при нарушении обмена жидкости между кровью и тканями', E'3'),
  (E'3f002e14-191a-4da1-aafd-35b5fd3981ec', E'2620d3d9-ec08-44da-bb97-61877b04ddaa', E'Снижение гидростатического давления в капиллярах', E'0'),
  (E'8dbc099b-e70a-403c-a4de-5da11513790a', E'2620d3d9-ec08-44da-bb97-61877b04ddaa', E'Усиление синтеза альбумина', E'1'),
  (E'd005ab57-b1f8-43bb-a2df-e396ffb1c47b', E'2620d3d9-ec08-44da-bb97-61877b04ddaa', E'Повышение гидростатического давления в венозном отделе микроциркуляторного русла', E'2'),
  (E'54e317f2-a62e-43ea-9bd6-93b881f3b083', E'2620d3d9-ec08-44da-bb97-61877b04ddaa', E'Полное прекращение капиллярной фильтрации', E'3'),
  (E'c47f5bd7-7919-4c84-bf25-e477f73f36f6', E'e7cdeeac-6335-45dc-9248-cb67850b49f3', E'Сухие альвеолы и уменьшение массы лёгких', E'0'),
  (E'8f0537cf-67b9-423a-a961-23def6dfd167', E'e7cdeeac-6335-45dc-9248-cb67850b49f3', E'Жидкость в интерстиции и альвеолах, тяжёлые влажные лёгкие', E'1'),
  (E'eafc1424-f11c-4a13-b580-c4c15362e7c7', E'e7cdeeac-6335-45dc-9248-cb67850b49f3', E'Изолированное расширение бронхов', E'2'),
  (E'a7de9260-fda6-4fb4-9d76-ec51029cdb90', E'e7cdeeac-6335-45dc-9248-cb67850b49f3', E'Массивное отложение амилоида в альвеолярных стенках', E'3'),
  (E'0572f814-55b9-45c3-8916-df4901ba39da', E'953e4d0d-a7fa-4da8-a309-c02aa644ab72', E'Повышает внутричерепное давление и может сдавливать жизненно важные структуры', E'0'),
  (E'11a9337b-eea2-456f-a8fd-41ca9e45a54d', E'953e4d0d-a7fa-4da8-a309-c02aa644ab72', E'Всегда вызывает массивное кровоизлияние', E'1'),
  (E'3a029005-b059-4e78-aed9-7b5cf811ee45', E'953e4d0d-a7fa-4da8-a309-c02aa644ab72', E'Немедленно превращается в гнойное воспаление', E'2'),
  (E'7a8a30c5-4d0b-4e01-9404-194796015cce', E'953e4d0d-a7fa-4da8-a309-c02aa644ab72', E'Снижает внутричерепное давление', E'3'),
  (E'cb44a49b-c4e2-40a2-a87c-ebbfb5765736', E'41c373dc-45d4-4e4e-a016-088646687b7f', E'Скопление гноя', E'0'),
  (E'7fc749ab-f3a8-4ee0-bcb3-f7b5e8284fdf', E'41c373dc-45d4-4e4e-a016-088646687b7f', E'Скопление крови в суставе', E'1'),
  (E'54b0ccb1-8336-4513-bcdf-7549c41b9e89', E'41c373dc-45d4-4e4e-a016-088646687b7f', E'Разрастание соединительной ткани', E'2'),
  (E'80ff4bcc-1b98-4a8c-ba8d-d34c2c2ea67c', E'41c373dc-45d4-4e4e-a016-088646687b7f', E'Скопление транссудата в серозной полости', E'3'),
  (E'66e559bd-9408-4e8e-beb3-3ec5787daa1d', E'6eaa174d-2bbf-4571-989c-8bfb05510380', E'При прекращении образования тканевой жидкости', E'0'),
  (E'7d72d43b-cc10-4d0a-a04d-2e9ab7b5b64b', E'6eaa174d-2bbf-4571-989c-8bfb05510380', E'Только вследствие гемолиза', E'1'),
  (E'b27c5135-d568-4c56-b511-218db9e1d9af', E'6eaa174d-2bbf-4571-989c-8bfb05510380', E'При недостаточном отведении лимфы и накоплении жидкости в тканях', E'2'),
  (E'49b64345-0376-4b0d-b7f8-bd5a3031c4f5', E'6eaa174d-2bbf-4571-989c-8bfb05510380', E'При изолированном снижении артериального притока', E'3'),
  (E'cc9015e3-710c-42b4-acdb-ccf030602c56', E'ee233422-707a-4595-b724-a40340dba071', E'Гемоперикард', E'0'),
  (E'248d33f7-38ab-4823-94ce-325648c439e3', E'ee233422-707a-4595-b724-a40340dba071', E'Хилоторакс', E'1'),
  (E'7ba74c80-98d3-4ccf-807b-c45a7f658eec', E'ee233422-707a-4595-b724-a40340dba071', E'Гидроцефалия', E'2'),
  (E'5f13de02-20fe-4769-968b-1e741b057ae7', E'ee233422-707a-4595-b724-a40340dba071', E'Гемартроз', E'3'),
  (E'6de0312d-ce78-4c53-9803-ac96c7ab9125', E'f2ef5a6a-09b9-4764-8847-82e2d6912f2d', E'Усилением притока артериальной крови в первом случае и затруднением венозного оттока во втором', E'0'),
  (E'cfc2f788-782b-4b96-8191-4f6639e0245e', E'f2ef5a6a-09b9-4764-8847-82e2d6912f2d', E'Оба состояния всегда вызваны тромбозом артерии', E'1'),
  (E'79db9ebc-199c-4ac2-9fb8-afd3a1cfb90d', E'f2ef5a6a-09b9-4764-8847-82e2d6912f2d', E'Венозный застой обязательно усиливает оксигенацию', E'2'),
  (E'461e524f-93a1-4e7d-96fc-7b8a393de760', E'f2ef5a6a-09b9-4764-8847-82e2d6912f2d', E'Артериальная гиперемия всегда вызывает некроз', E'3'),
  (E'ac4a0466-b517-4e5c-9658-63427a5cf84f', E'352bbc63-379f-4fe3-9bbf-45b2cedcde5d', E'Бледная и малокровная', E'0'),
  (E'8cabeeea-4147-485a-ac96-ddac80f62165', E'352bbc63-379f-4fe3-9bbf-45b2cedcde5d', E'Всегда плотная и рубцовая', E'1');
INSERT INTO public.question_options (id, question_id, option_text, sort_order) VALUES
  (E'5aad2320-9060-4a55-be62-96dbc55ed072', E'352bbc63-379f-4fe3-9bbf-45b2cedcde5d', E'Ярко-красная только из-за усиленного притока', E'2'),
  (E'b5cfafbf-2dbc-452f-9673-e1b66525b9fa', E'352bbc63-379f-4fe3-9bbf-45b2cedcde5d', E'Цианотичная, полнокровная, часто отёчная', E'3'),
  (E'e2aa490e-e16d-45be-8fe4-07f0d4581ca5', E'6f28a422-a177-43c0-8d6f-41f9cf127085', E'Полное исчезновение капилляров без пигмента', E'0'),
  (E'cd237804-038e-4b7e-ae97-69126856f223', E'6f28a422-a177-43c0-8d6f-41f9cf127085', E'Только жировая дистрофия', E'1'),
  (E'bba954f4-a027-4c5d-b7b2-ad149dbae5e7', E'6f28a422-a177-43c0-8d6f-41f9cf127085', E'Бурая индурация с гемосидерозом и склерозом', E'2'),
  (E'd6adf7f8-3593-4bd9-9f0c-b50c7c4ca206', E'6f28a422-a177-43c0-8d6f-41f9cf127085', E'Обязательный казеозный некроз', E'3'),
  (E'be22f355-7204-4a58-84c8-d2400a0fe039', E'172e481c-e541-42e8-81c3-4c2e6c7254b7', E'Нейтрофилы синтезируют меланин', E'0'),
  (E'0236a7e6-9bf9-48c6-b1d7-ce35326f6212', E'172e481c-e541-42e8-81c3-4c2e6c7254b7', E'Макрофаги поглощают гемосидерин из разрушенных эритроцитов', E'1'),
  (E'8adab9d4-45ad-4397-a645-21ea0629ecd4', E'172e481c-e541-42e8-81c3-4c2e6c7254b7', E'Эпителиоциты превращаются в адипоциты', E'2'),
  (E'57f5d217-2fc7-4c1c-ac0d-7aeecf655faf', E'172e481c-e541-42e8-81c3-4c2e6c7254b7', E'Фибробласты поглощают амилоид', E'3'),
  (E'd8454498-de18-4060-8f6e-8262f4cfee5f', E'70ee3ec7-7252-44c8-83f9-50a68dbfec7a', E'Гемосидероз и застойный склероз', E'0'),
  (E'2ecfd2ee-6045-41db-8395-35dda3b10820', E'70ee3ec7-7252-44c8-83f9-50a68dbfec7a', E'Изолированная кальцификация', E'1'),
  (E'e1f47053-fbd0-41af-8cd2-3aa100a3daa7', E'70ee3ec7-7252-44c8-83f9-50a68dbfec7a', E'Гнойное расплавление ткани', E'2'),
  (E'092dc978-8fb9-4964-acc3-3223eb4f522e', E'70ee3ec7-7252-44c8-83f9-50a68dbfec7a', E'Накопление жира в бронхах', E'3'),
  (E'316b7ddf-d62c-4201-81a9-a0ba572a9982', E'c66cd57a-08b9-4d3c-8680-c8bc4c588b7d', E'Равномерно бледная', E'0'),
  (E'fa08a9ef-809e-49dc-af00-2a8f86d48f79', E'c66cd57a-08b9-4d3c-8680-c8bc4c588b7d', E'С множественными лимфатическими полостями', E'1'),
  (E'4d73443f-5e64-4b9f-9ce6-a7947514a016', E'c66cd57a-08b9-4d3c-8680-c8bc4c588b7d', E'Покрытая фибринозными плёнками', E'2'),
  (E'5a6df8c8-9639-407a-b349-f2cfae7ff774', E'c66cd57a-08b9-4d3c-8680-c8bc4c588b7d', E'Мускатная: тёмно-красные центры долек и более светлая периферия', E'3'),
  (E'85317d1d-dd7d-43f1-ae1b-7d9783bbe048', E'63451ceb-d0f3-44c7-8a13-3fabd5d3ce10', E'Изолированное усиление левого желудочка при нормальном оттоке', E'0'),
  (E'c29e6c58-f4cf-4064-bab3-62a561143236', E'63451ceb-d0f3-44c7-8a13-3fabd5d3ce10', E'Острая гиперемия кожи', E'1'),
  (E'3e83dc57-caf1-4dd3-8f01-d4cfeffc8a9b', E'63451ceb-d0f3-44c7-8a13-3fabd5d3ce10', E'Правожелудочковая сердечная недостаточность', E'2'),
  (E'dcc08909-6bf4-4a0d-9ed7-32f5c5fbdaaa', E'63451ceb-d0f3-44c7-8a13-3fabd5d3ce10', E'Усиление лимфообразования при сохранном венозном оттоке', E'3'),
  (E'47e2b318-875f-43aa-99a1-200a0095b500', E'152e3a5d-f0c7-42a3-835c-426a975d8d3f', E'Гидроторакс', E'0'),
  (E'3e77157f-e5a4-44d6-bfc0-1c069abfc5db', E'152e3a5d-f0c7-42a3-835c-426a975d8d3f', E'Асцит', E'1'),
  (E'6b83e9b3-d92e-4e08-81fd-011fae65c12f', E'152e3a5d-f0c7-42a3-835c-426a975d8d3f', E'Гемоперикард', E'2'),
  (E'02d5065a-242b-4a08-8b5f-0e3fd82a5c64', E'152e3a5d-f0c7-42a3-835c-426a975d8d3f', E'Гидроцефалия', E'3'),
  (E'7954e3bd-6739-419e-bbec-0926cac83e5a', E'83c56849-de85-4563-b888-c952b1de33b2', E'Асцит, спленомегалия и расширение портокавальных анастомозов', E'0'),
  (E'549930f7-ca3a-4dd1-9207-7e679b647172', E'83c56849-de85-4563-b888-c952b1de33b2', E'Отёк мозга и сужение вен пищевода', E'1'),
  (E'3773137a-4208-4c6f-a145-03fd6c10ea8f', E'83c56849-de85-4563-b888-c952b1de33b2', E'Атрофия селезёнки без венозных изменений', E'2'),
  (E'681b6f6f-1581-4a1c-93d7-e56583b5e43e', E'83c56849-de85-4563-b888-c952b1de33b2', E'Только артериальная гиперемия кишечника', E'3'),
  (E'129b6e7d-1361-4b0a-ad90-979f5085952c', E'51a975dd-e561-4780-9af2-217d28bb28db', E'Прекращение артериального притока', E'0'),
  (E'3be9ecea-1bda-4d43-93cf-5ffc4340537e', E'51a975dd-e561-4780-9af2-217d28bb28db', E'Накопление воздуха в пульпе', E'1'),
  (E'd758ec38-4df0-409e-8bfa-62f77a0db996', E'51a975dd-e561-4780-9af2-217d28bb28db', E'Снижение числа лимфатических сосудов без венозных изменений', E'2'),
  (E'3a41a002-d9b6-47dc-a995-a6fa17f5b0f0', E'51a975dd-e561-4780-9af2-217d28bb28db', E'Длительное повышение венозного давления', E'3'),
  (E'22807702-caa8-4742-8701-0ae13ce9c94a', E'b86b4260-a9f2-4bbf-8cda-539fb8c9b06f', E'Накопление лимфы в интерстиции', E'0'),
  (E'594ed6d1-031d-4daa-b3ad-0f15a83147cf', E'b86b4260-a9f2-4bbf-8cda-539fb8c9b06f', E'Увеличение числа эритроцитов внутри сосудов', E'1'),
  (E'ff467d80-6f83-4398-b078-16359912a217', E'b86b4260-a9f2-4bbf-8cda-539fb8c9b06f', E'Выход крови из сосудистого русла наружу, в полости или ткани', E'2'),
  (E'8540825e-d1c7-4538-89f7-5934b42afdd2', E'b86b4260-a9f2-4bbf-8cda-539fb8c9b06f', E'Расширение капилляров без выхода крови', E'3'),
  (E'de16dac2-8023-436d-9f40-31060eafa5ca', E'92abe209-9f93-4c84-859a-fabbe806b728', E'Связанное только с повышением числа тромбоцитов', E'0'),
  (E'8e8ab57c-15fb-4dbf-bc0b-00d8a8aaf399', E'92abe209-9f93-4c84-859a-fabbe806b728', E'Возникающее при разрушении стенки сосуда патологическим процессом', E'1'),
  (E'aa5215e9-49c9-4efb-8ec6-ed3aed00b9f3', E'92abe209-9f93-4c84-859a-fabbe806b728', E'Возникающее при любом повреждении кожи', E'2'),
  (E'ec444b3f-7f35-4f6b-853f-aa1d86aad43b', E'92abe209-9f93-4c84-859a-fabbe806b728', E'Выход лимфы из лимфатического сосуда', E'3'),
  (E'cd9f6e1e-aa3d-4e15-b8c7-c9f2dda7aaf2', E'bea7dafc-e6d0-4c0e-a96b-f4de443a8be2', E'Выход эритроцитов через стенку микроциркуляторных сосудов', E'0'),
  (E'652c42f1-7122-460a-ab50-76c839514c8c', E'bea7dafc-e6d0-4c0e-a96b-f4de443a8be2', E'Разрыв крупной артерии с образованием гематомы', E'1'),
  (E'9e585c26-2b0b-4e8b-b56f-01e14305d95f', E'bea7dafc-e6d0-4c0e-a96b-f4de443a8be2', E'Скопление транссудата в плевре', E'2'),
  (E'cd154042-b205-44a9-b0d0-c6a8d6bc2c8f', E'bea7dafc-e6d0-4c0e-a96b-f4de443a8be2', E'Отложение фибрина внутри сосуда без выхода крови', E'3'),
  (E'26536c6e-a0f2-45e2-944f-d4a98e230f71', E'38abef5b-7ab5-46f2-aa82-f77507874d2d', E'Гематома состоит из лимфы, инфильтрация из гноя', E'0'),
  (E'0db71111-30fd-42da-9a8c-8c11122d8d51', E'38abef5b-7ab5-46f2-aa82-f77507874d2d', E'Гематома всегда микроскопическая', E'1'),
  (E'c6fa9e52-2551-4bed-80a0-7e1941ca2edc', E'38abef5b-7ab5-46f2-aa82-f77507874d2d', E'Морфологического различия нет', E'2'),
  (E'db852e16-8db7-4a03-a2d4-95b4a57a6550', E'38abef5b-7ab5-46f2-aa82-f77507874d2d', E'Гематома образует полость с кровью, инфильтрация пропитывает ткань без полости', E'3'),
  (E'070f2740-7a2a-46ae-834e-d960f55885aa', E'b895e7df-ec0d-46a9-bec8-d2b29bb7cde2', E'Гемоперитонеум', E'0'),
  (E'ddc668a6-5153-4f16-88a3-e37477d4aa83', E'b895e7df-ec0d-46a9-bec8-d2b29bb7cde2', E'Гемоперикард', E'1'),
  (E'1af6331a-7e91-40e9-8bb8-cc35bf726747', E'b895e7df-ec0d-46a9-bec8-d2b29bb7cde2', E'Гемоторакс', E'2'),
  (E'2aae64f9-141b-4d30-b4de-ee281db2e475', E'b895e7df-ec0d-46a9-bec8-d2b29bb7cde2', E'Гемартроз', E'3'),
  (E'5e7bf70c-0dea-42c5-9b9c-096ecd60cd01', E'925851f3-d499-4182-b127-1574ac09aef0', E'Только цвет крови', E'0'),
  (E'1bb584e3-cb55-423e-802f-882df53010cd', E'925851f3-d499-4182-b127-1574ac09aef0', E'Объём и локализация очага, повреждение ткани и повышение внутричерепного давления', E'1'),
  (E'0af9ee1b-c50b-4220-9f37-b10fc5858c49', E'925851f3-d499-4182-b127-1574ac09aef0', E'Обязательное наличие наружной раны', E'2'),
  (E'2d24b575-881b-4647-a422-0a8be41a2b74', E'925851f3-d499-4182-b127-1574ac09aef0', E'Количество лимфы вокруг очага', E'3'),
  (E'487f10d7-05b3-4e2a-983b-ede61c8482c4', E'83311761-c9e8-4aa3-b50e-cb559c13d932', E'Рассасывание крови или организация очага', E'0'),
  (E'938f88a0-10c8-4dc3-bf43-ef6104f1af22', E'83311761-c9e8-4aa3-b50e-cb559c13d932', E'Обязательное нагноение', E'1'),
  (E'fe4add60-061d-423a-b90f-a2d744010589', E'83311761-c9e8-4aa3-b50e-cb559c13d932', E'Неизбежный амилоидоз', E'2'),
  (E'eeea3a66-d4e7-4842-a73b-a1d6cca84cc6', E'83311761-c9e8-4aa3-b50e-cb559c13d932', E'Постоянное увеличение очага независимо от причины', E'3'),
  (E'2a7238b3-465c-4a19-a6d8-c9d4f57d8e38', E'4b653848-c6fa-4409-ae4e-56dcf7a035a3', E'Изолированную артериальную гипертензию', E'0'),
  (E'1a761c82-e7b0-4bfe-9d36-5d42d69f7c4d', E'4b653848-c6fa-4409-ae4e-56dcf7a035a3', E'Увеличение числа эритроцитов при нормальном гемостазе', E'1'),
  (E'33312add-aeaf-46b6-8a97-6792e207637f', E'4b653848-c6fa-4409-ae4e-56dcf7a035a3', E'Накопление транссудата в серозных полостях', E'2'),
  (E'e531cc5d-a8d5-4fca-986c-32c23b22522f', E'4b653848-c6fa-4409-ae4e-56dcf7a035a3', E'Повышенную склонность к кровотечениям и кровоизлияниям вследствие нарушений гемостаза', E'3'),
  (E'20ddf950-1efa-4cbc-b173-474f3ea64b42', E'b5aeaad9-a52f-4c15-a87f-3417d354cfb6', E'Избыток альбумина в плазме', E'0'),
  (E'8452bc14-2bc4-4e6e-84d7-65d9a85bfd05', E'b5aeaad9-a52f-4c15-a87f-3417d354cfb6', E'Усиление лимфатического оттока', E'1'),
  (E'7a64f4e2-26ff-496a-9980-1f9fa9d32654', E'b5aeaad9-a52f-4c15-a87f-3417d354cfb6', E'Снижение числа тромбоцитов и нарушение первичного гемостаза', E'2'),
  (E'962ed4b0-efb0-42d1-aae2-98c3c3002213', E'b5aeaad9-a52f-4c15-a87f-3417d354cfb6', E'Усиление образования коллагена в дерме', E'3'),
  (E'c21bf000-f488-45cf-aa1c-b34870a43c6a', E'56da18e9-c6d7-4c34-b002-7728425149d5', E'Изолированную гипотензию без нарушений гемостаза', E'0'),
  (E'a205948a-9b7d-4123-b750-f6eaccc7b699', E'56da18e9-c6d7-4c34-b002-7728425149d5', E'Диссеминированное образование микротромбов с потреблением факторов свёртывания и последующей кровоточивостью', E'1'),
  (E'73af536a-a9cf-4ba8-926a-1936778a3caf', E'56da18e9-c6d7-4c34-b002-7728425149d5', E'Тромбоз одной крупной артерии', E'2'),
  (E'900a0de6-4443-4b9c-9661-930fbde77b97', E'56da18e9-c6d7-4c34-b002-7728425149d5', E'Увеличение объёма лимфы без свёртывания крови', E'3'),
  (E'dee7c01c-eaf9-4be9-ab39-45ca110c7b7c', E'dcb579d0-f766-4e10-b31d-27058020c329', E'Сначала гиперкоагуляция и микротромбы, затем коагулопатия потребления', E'0'),
  (E'31c2fc63-a8be-4618-9a13-9e37417773aa', E'dcb579d0-f766-4e10-b31d-27058020c329', E'Сначала гипокоагуляция без тромбов, затем восстановление', E'1'),
  (E'4139b8ff-3b0f-4db8-ae8d-c2e6dae1aba3', E'9fde21fe-622f-4576-ba41-a15d02fea248', E'На эндокарде над повреждённой стенкой левого желудочка', E'0'),
  (E'5c08f52b-a07a-4c87-b856-3a9c92085a4a', E'9fde21fe-622f-4576-ba41-a15d02fea248', E'В перикардиальной полости', E'1'),
  (E'cabfd329-c157-4454-8565-414e1efe603f', E'9fde21fe-622f-4576-ba41-a15d02fea248', E'Только в здоровом правом предсердии', E'2'),
  (E'1e406930-14fd-477d-b86d-bbb1ef82f52e', E'9fde21fe-622f-4576-ba41-a15d02fea248', E'Только внутри клапана', E'3'),
  (E'0fbf8d13-1ce7-4cbe-a5fb-df898842abfd', E'1232583a-c69c-4f00-995d-76343dd4f368', E'Реканализации', E'0'),
  (E'92e9981b-42b0-4a9a-9fc0-50c8a9fea906', E'1232583a-c69c-4f00-995d-76343dd4f368', E'Петрификации', E'1'),
  (E'881c8271-7d5b-4c92-8cac-4ba83977d046', E'1232583a-c69c-4f00-995d-76343dd4f368', E'Тромбоэмболии', E'2'),
  (E'fbb40415-e47e-482e-9abb-697c33480993', E'1232583a-c69c-4f00-995d-76343dd4f368', E'Организации', E'3'),
  (E'15f85047-03fb-40be-8353-080dc8b15094', E'8335ee21-5584-4b75-b243-20eca12aa1f1', E'Против кровотока', E'0'),
  (E'fb6d757d-0153-4ceb-b574-dd1cb9039c99', E'8335ee21-5584-4b75-b243-20eca12aa1f1', E'По направлению кровотока', E'1'),
  (E'e1c343ab-0aae-43c4-bf8f-d315dfdc1d69', E'8335ee21-5584-4b75-b243-20eca12aa1f1', E'Из вен в артерии через дефект перегородки', E'2'),
  (E'364f0629-befa-4c2c-9412-6c8af8f41340', E'8335ee21-5584-4b75-b243-20eca12aa1f1', E'Только после смерти', E'3'),
  (E'864b0d3c-861b-4c0f-8520-8823f6777d9a', E'a6012c5b-49a2-4c75-898b-66c4a703bb88', E'Попадания жира костного мозга в повреждённые сосуды', E'0'),
  (E'72dd1286-c241-4ecb-9fd5-b06868ddd2d5', E'a6012c5b-49a2-4c75-898b-66c4a703bb88', E'Отложения кальция в артериях', E'1'),
  (E'07509478-b9fa-46a5-9590-5de33adb1515', E'a6012c5b-49a2-4c75-898b-66c4a703bb88', E'Воздуха при обычном вдохе', E'2'),
  (E'70c399e2-1861-49fb-95ab-2522b8913b2a', E'a6012c5b-49a2-4c75-898b-66c4a703bb88', E'Исчезновения тромбоцитов', E'3'),
  (E'69c5e935-644e-4f30-876a-e6c2975accf3', E'16785903-7360-4449-ad97-0d4638f0ec7a', E'Выделением растворённых газов при быстром снижении давления', E'0'),
  (E'dc2622f4-e789-4a7b-b454-41dd61426192', E'16785903-7360-4449-ad97-0d4638f0ec7a', E'Только попаданием воздуха из повреждённой вены', E'1'),
  (E'1dc400a2-fdb1-496c-b6e2-8ca7a9f336a9', E'16785903-7360-4449-ad97-0d4638f0ec7a', E'Скоплением эритроцитов', E'2'),
  (E'b77af0e4-5ca0-4e50-bddc-e1177805d980', E'16785903-7360-4449-ad97-0d4638f0ec7a', E'Ростом бактерий в тромбе', E'3'),
  (E'61a4aada-14ea-4b12-8d3d-3b4a3d36639a', E'1a24345e-a94a-47c1-8dcb-a975babf76d5', E'Попадании внешних частиц в сосудистое русло', E'0'),
  (E'f71df72a-501e-4e11-bd7d-03db463ea2da', E'1a24345e-a94a-47c1-8dcb-a975babf76d5', E'Физиологическом расширении артериол', E'1'),
  (E'1efb89c4-5d9b-4a91-b4dc-0b2406216a7c', E'1a24345e-a94a-47c1-8dcb-a975babf76d5', E'Росте фибриногена без тромба', E'2'),
  (E'e42fbcf6-165e-41d1-9610-a481ae0cbd54', E'1a24345e-a94a-47c1-8dcb-a975babf76d5', E'Усилении лимфооттока', E'3');
INSERT INTO public.question_options (id, question_id, option_text, sort_order) VALUES
  (E'c2508fe3-b022-46f6-a77b-c2b9b340ded0', E'0b0a2985-7e1d-45b8-bbb4-a37aea86c53d', E'Острое расширение и перегрузка правого желудочка', E'0'),
  (E'6b6e8106-d687-4226-bd0c-10bf81c20ffb', E'0b0a2985-7e1d-45b8-bbb4-a37aea86c53d', E'Гипертрофия левого желудочка при гипертонии', E'1'),
  (E'7da94cbb-6578-41a7-bfb7-493389c9e96a', E'0b0a2985-7e1d-45b8-bbb4-a37aea86c53d', E'Воспаление плевры', E'2'),
  (E'41eb8f45-dab4-4c60-9842-cbf8aedfacaf', E'0b0a2985-7e1d-45b8-bbb4-a37aea86c53d', E'Воздух в перикарде', E'3'),
  (E'496e42eb-d45d-4b73-97c6-79d82633f175', E'1f40cfac-ad88-446a-bbd9-1a645e6c8c9a', E'Проявления множественной или повторной тромбоэмболии сосудов органов', E'0'),
  (E'06b64a34-7b69-44ff-a3e6-286255bf117b', E'1f40cfac-ad88-446a-bbd9-1a645e6c8c9a', E'Обычный синяк', E'1'),
  (E'8a1e4b6b-3aac-496f-a078-e49d3921bab5', E'1f40cfac-ad88-446a-bbd9-1a645e6c8c9a', E'Изолированная гипертензия', E'2'),
  (E'abbaeebe-ab2d-4692-80da-bb145afa1a99', E'1f40cfac-ad88-446a-bbd9-1a645e6c8c9a', E'Нарушение лимфооттока без сосудистой закупорки', E'3'),
  (E'6d36d545-a0a1-465e-8f77-4dacea3c9fb6', E'd13cd01e-b99d-4587-92bd-e0d916db1b42', E'Спазма артерии', E'0'),
  (E'f2dfa8df-3348-4ad1-ad0c-4cdde356f57a', E'd13cd01e-b99d-4587-92bd-e0d916db1b42', E'Разрыва вены', E'1'),
  (E'2b183bb5-7d3b-4f10-a433-3b7cb4709c8d', E'd13cd01e-b99d-4587-92bd-e0d916db1b42', E'Усиления венозного оттока', E'2'),
  (E'2d6a861a-e803-4b0e-bbac-f88b93eb7b03', E'd13cd01e-b99d-4587-92bd-e0d916db1b42', E'Петрификации тромба без сужения сосуда', E'3'),
  (E'3f9cca98-c534-463f-a6fd-565307bdd0ac', E'fb5ba8cc-7ed5-4d7c-82d9-39293342cd53', E'Гиалиново-капельную дистрофию, гидропическую дистрофию, роговую дистрофию', E'0'),
  (E'4be05d0e-c0ce-4397-b348-d20408b2eeb5', E'dcb579d0-f766-4e10-b31d-27058020c329', E'Сначала фиброз, затем лимфедема', E'2'),
  (E'e47c72b5-3c15-4761-a227-7ce6f77e2e54', E'dcb579d0-f766-4e10-b31d-27058020c329', E'Сначала гемолиз, затем обязательный амилоидоз', E'3'),
  (E'79359d5d-54ec-4a35-9317-60d986a90aad', E'32d2d32d-3c72-4fdb-98d0-47d08c71db88', E'Свёртывание полностью не активируется', E'0'),
  (E'7df55a08-b49b-436e-8330-d42f4c3c5a38', E'32d2d32d-3c72-4fdb-98d0-47d08c71db88', E'Эритроциты превращаются в лимфоциты', E'1'),
  (E'500d5b59-49c7-48a6-b630-8cf19ec02c02', E'32d2d32d-3c72-4fdb-98d0-47d08c71db88', E'Сосуды всегда расширяются без повреждения эндотелия', E'2'),
  (E'bbad8164-0118-4c2e-84b8-3f8c7ca80aab', E'32d2d32d-3c72-4fdb-98d0-47d08c71db88', E'Микротромбообразование расходует тромбоциты и факторы свёртывания', E'3'),
  (E'857f044e-baf6-43cb-870e-2a46f659f941', E'9dc686b7-93d0-460c-99f0-251a2bdd8984', E'Только жировая дистрофия эпителия лоханки', E'0'),
  (E'1bfb2b7a-45ec-4190-a07f-dbef76c04427', E'9dc686b7-93d0-460c-99f0-251a2bdd8984', E'Обязательные лимфатические кисты', E'1'),
  (E'92ec0545-2d50-4912-881a-1c8dc9d32c33', E'9dc686b7-93d0-460c-99f0-251a2bdd8984', E'Микротромбы в микроциркуляторном русле с ишемическим повреждением', E'2'),
  (E'e5901378-cdad-49b2-986b-ef1e858a23a0', E'9dc686b7-93d0-460c-99f0-251a2bdd8984', E'Увеличение числа нефронов', E'3'),
  (E'7ea85e94-016e-4ab4-8e51-f9105f348cd4', E'7afbaf10-962e-4a31-9977-0a4fbac5503e', E'Эмоциональное переживание без физиологических нарушений', E'0'),
  (E'5e53c95d-b765-4035-9441-62b7e225557c', E'7afbaf10-962e-4a31-9977-0a4fbac5503e', E'Острое системное нарушение кровообращения, микроциркуляции и функций органов', E'1'),
  (E'681543af-bcbc-4ef9-a7be-710407d6c0d7', E'7afbaf10-962e-4a31-9977-0a4fbac5503e', E'Локальное расширение капилляров', E'2'),
  (E'fbd6e8a1-f0c9-423b-805d-2483f8253fec', E'7afbaf10-962e-4a31-9977-0a4fbac5503e', E'Хроническую водянку одной серозной полости', E'3'),
  (E'85dcaca1-326d-4ae2-b300-7a9f2a66b349', E'5c97f5fb-45fb-4b87-b270-c3811db6360d', E'Гиповолемический', E'0'),
  (E'0de23206-fa14-496b-8529-a98449e9a880', E'5c97f5fb-45fb-4b87-b270-c3811db6360d', E'Кардиогенный', E'1'),
  (E'9c91efca-56f8-4cdc-bd70-99da941e1c72', E'5c97f5fb-45fb-4b87-b270-c3811db6360d', E'Анафилактический', E'2'),
  (E'37314fe0-d235-4d67-8f25-b0f144e29a1c', E'5c97f5fb-45fb-4b87-b270-c3811db6360d', E'Септический', E'3'),
  (E'970da9bb-1d3d-447c-8a3d-46e33d736022', E'89269d46-9285-4d40-8231-d4be241346fb', E'Потеря лимфы как единственная причина', E'0'),
  (E'9d747ef6-7993-4b20-9c95-a7d793a341b3', E'89269d46-9285-4d40-8231-d4be241346fb', E'Только расширение кожных артериол при нормальном выбросе', E'1'),
  (E'6e0c2d4f-f706-450e-a3d3-ac02bdb5b6ed', E'89269d46-9285-4d40-8231-d4be241346fb', E'Повышение онкотического давления плазмы', E'2'),
  (E'9836e11b-0bf4-49e7-be41-553aa19375f9', E'89269d46-9285-4d40-8231-d4be241346fb', E'Резкое снижение насосной функции сердца и сердечного выброса', E'3'),
  (E'ccbf8aa2-b24e-4a23-a70f-38090f69adda', E'2783194f-14d0-4114-a9cf-97524b9ca403', E'Сдавление одной крупной вены', E'0'),
  (E'62b0e211-c3ec-4318-abce-14b964e14198', E'2783194f-14d0-4114-a9cf-97524b9ca403', E'Изолированное накопление амилоида в миокарде', E'1'),
  (E'82878e3e-65ff-4abf-8f45-67b8665e621a', E'2783194f-14d0-4114-a9cf-97524b9ca403', E'Системная реакция на инфекцию с нарушением сосудистого тонуса и микроциркуляции', E'2'),
  (E'78e7fef3-55cd-45df-90c0-0937a1b9cd8a', E'2783194f-14d0-4114-a9cf-97524b9ca403', E'Обязательная массивная кровопотеря из артерии', E'3'),
  (E'c82bec64-c96c-40cd-8fca-6c6099921011', E'239eb57a-f8e8-418e-bd78-5212112f764a', E'Обязательное увеличение числа нефронов', E'0'),
  (E'88c49025-e77a-4a58-b005-3603fba38f45', E'239eb57a-f8e8-418e-bd78-5212112f764a', E'Острое ишемическое повреждение канальцев вследствие гипоперфузии', E'1'),
  (E'd8f8fd7e-5406-4c11-aa34-890f926bf5a3', E'239eb57a-f8e8-418e-bd78-5212112f764a', E'Только амилоид в лоханке', E'2'),
  (E'0bb71d68-e045-41f0-b4c5-a3c7029231f1', E'239eb57a-f8e8-418e-bd78-5212112f764a', E'Полное отсутствие морфологических изменений при любой длительности', E'3'),
  (E'3c57069d-376c-4915-bc35-307ac5c8ae5e', E'fb5ba8cc-7ed5-4d7c-82d9-39293342cd53', E'Мукоидное набухание, фибриноидное набухание, гиалиноз', E'1'),
  (E'a49e3f8f-342a-4bb0-ad2d-f0b9ff3eee5f', E'fb5ba8cc-7ed5-4d7c-82d9-39293342cd53', E'Стеатоз, ожирение, гликогеноз', E'2'),
  (E'7e4c66a6-d175-4f5e-9f0f-fa4d2f528796', E'fb5ba8cc-7ed5-4d7c-82d9-39293342cd53', E'Меланоз, гемосидероз, желтуху', E'3'),
  (E'688314dd-04cd-4b78-847f-15ef7df8ed9a', E'c260ff7d-b91c-4845-81cd-49ff0a7fb6fd', E'Амилоидное сморщивание органа', E'0'),
  (E'14d3a40f-4628-45bd-b149-b39c9be9c57b', E'c260ff7d-b91c-4845-81cd-49ff0a7fb6fd', E'Полное восстановление ткани после устранения причины', E'1'),
  (E'adb8fb3d-7b24-4419-b8e0-1c37e3cee907', E'c260ff7d-b91c-4845-81cd-49ff0a7fb6fd', E'Организация очага с обязательным формированием рубца', E'2'),
  (E'e1cd8f39-f750-4877-b9fc-6763fd2854d5', E'c260ff7d-b91c-4845-81cd-49ff0a7fb6fd', E'Переход в фибриноидный некроз во всех случаях', E'3'),
  (E'24b40f8a-3e2e-4aec-8107-1b131099dde2', E'3c9d35e3-1e71-4e92-912a-def790bf9fb0', E'Оно бывает только в жировой ткани', E'0'),
  (E'5d594902-1a4a-44e3-b82d-70f248886499', E'3c9d35e3-1e71-4e92-912a-def790bf9fb0', E'Оно может быть системным или локальным', E'1'),
  (E'4279fd0d-14c5-4233-8d1b-b93d840e4cf2', E'3c9d35e3-1e71-4e92-912a-def790bf9fb0', E'Оно всегда обратимо', E'2'),
  (E'010f00e0-7877-4c15-bbdd-8717067528ff', E'3c9d35e3-1e71-4e92-912a-def790bf9fb0', E'Оно является разновидностью амилоидоза', E'3'),
  (E'92077f34-0332-4076-9266-a05a82a5698d', E'45c1ee9a-1b90-4c78-ac7c-9a82243126ed', E'Липогиалин', E'0'),
  (E'f6d90340-eeda-4d8a-bb7f-6ebfbe1472bf', E'45c1ee9a-1b90-4c78-ac7c-9a82243126ed', E'Фибрин', E'1'),
  (E'6b62c751-033e-4d40-822c-e69415812dd4', E'45c1ee9a-1b90-4c78-ac7c-9a82243126ed', E'Амилоид AL', E'2'),
  (E'6f3138d9-4539-4bfd-9fc3-3c0f8396e896', E'45c1ee9a-1b90-4c78-ac7c-9a82243126ed', E'Эластин', E'3'),
  (E'e91457a4-9f7f-45e1-9741-7d6dc1fa309e', E'45f13b67-a42a-4ba9-9cea-bfac1eb5c9cf', E'Преимущественно увеличение объёма существующих адипоцитов, увеличение их количества или сочетание обоих механизмов', E'0'),
  (E'72287d5d-a12c-420e-990e-ebf51554ae7f', E'45f13b67-a42a-4ba9-9cea-bfac1eb5c9cf', E'Замещение жировых клеток соединительной тканью с последующим накоплением липидов в межклеточном веществе', E'1'),
  (E'9ecdb747-f078-4ee4-8b66-2764d967ab9c', E'45f13b67-a42a-4ba9-9cea-bfac1eb5c9cf', E'Увеличение количества липидов в клетках паренхиматозных органов при неизменной массе жировых депо', E'2'),
  (E'0dddde5f-332b-4760-ad42-cdec271083aa', E'45f13b67-a42a-4ba9-9cea-bfac1eb5c9cf', E'Нарушение распада внеклеточного амилоида с его накоплением вокруг адипоцитов', E'3'),
  (E'2201cfd1-6965-4fa9-85c9-3564c45328be', E'd162be65-291b-44f2-87ab-a37d944272c9', E'Гиперпластический', E'0'),
  (E'bcff6768-18e1-421f-bd30-b652d9c647e3', E'd162be65-291b-44f2-87ab-a37d944272c9', E'Гипертрофический', E'1'),
  (E'cc50d6cd-7456-4e6c-a198-3a22ac23c0fe', E'd162be65-291b-44f2-87ab-a37d944272c9', E'Амилоидный', E'2'),
  (E'ac58fe00-ce06-4050-bfc1-150cd5e5ad72', E'd162be65-291b-44f2-87ab-a37d944272c9', E'Фиброзный', E'3'),
  (E'375bb14c-38f2-42df-b642-85dedad27524', E'aa1adc4c-56a0-4c22-b615-5f625e96e256', E'Гиперпластический, гипертрофический и смешанный', E'0'),
  (E'ecf6b417-c443-40f7-9966-ee1b76777b55', E'47981803-2c1f-4c7d-85b5-44e55dcc0f1c', E'Глубокая деструкция соединительной ткани с образованием фибриноида', E'0'),
  (E'bf6554c6-18ab-4f30-84a7-a9f86da3afb1', E'47981803-2c1f-4c7d-85b5-44e55dcc0f1c', E'Поверхностное повреждение основного вещества соединительной ткани', E'1'),
  (E'2a34a0dd-e248-429b-9703-34e5fc265436', E'47981803-2c1f-4c7d-85b5-44e55dcc0f1c', E'Отложение амилоида в стенках сосудов', E'2'),
  (E'9999eeef-5d63-470c-af06-ffcc9f37f73a', E'47981803-2c1f-4c7d-85b5-44e55dcc0f1c', E'Накопление триглицеридов в адипоцитах', E'3'),
  (E'a8dbfbfa-87ba-4d1e-b9f6-3f41ecef2393', E'aedee360-0bef-48db-ad80-1e3afaf0d80b', E'Поверхностное изменение основного вещества без деструкции', E'0'),
  (E'95bfabd4-f5ac-44be-9a68-c63b7c913db9', E'aedee360-0bef-48db-ad80-1e3afaf0d80b', E'Глубокая дезорганизация соединительной ткани с образованием фибриноида', E'1'),
  (E'd287524f-8f95-4d83-bfc4-daa3980b58f5', E'aedee360-0bef-48db-ad80-1e3afaf0d80b', E'Изолированное накопление холестерина в макрофагах', E'2'),
  (E'c1705fe3-2b6e-4060-95ea-0d6d466aa7b8', E'aedee360-0bef-48db-ad80-1e3afaf0d80b', E'Увеличение числа жировых клеток', E'3'),
  (E'6ca2253f-6d81-40e3-b69b-b06f44ee614b', E'ffa3703e-ad56-47a8-a009-23333aee19fe', E'Накопление внутриклеточных капель нейтрального жира', E'0'),
  (E'ed498212-f3c4-4239-9da5-16cab8a06339', E'ffa3703e-ad56-47a8-a009-23333aee19fe', E'Образование плотных однородных белковых масс, напоминающих гиалин', E'1'),
  (E'79ebe144-f41f-4e6f-904f-061c653f8604', E'ffa3703e-ad56-47a8-a009-23333aee19fe', E'Внеклеточное отложение фибриллярного амилоида', E'2'),
  (E'4172c974-b5fa-4764-a3f8-c0b96b327eed', E'ffa3703e-ad56-47a8-a009-23333aee19fe', E'Отложение солей кальция в повреждённой ткани', E'3'),
  (E'09509f82-4726-4609-bcee-28d80c69fe7e', E'586542ea-a8c8-4818-b995-40e0d240e3fc', E'Сосудистыми кризами и повреждением стенки сосудов', E'0'),
  (E'c2f9f323-d67d-4686-8461-02df8a90d39c', E'586542ea-a8c8-4818-b995-40e0d240e3fc', E'Недостатком витамина C', E'1'),
  (E'6a9536ec-3fd5-482b-bd65-18a35392df03', E'586542ea-a8c8-4818-b995-40e0d240e3fc', E'Избыточным образованием меланина', E'2'),
  (E'122236da-8664-4e45-be76-235c8c8c40e0', E'586542ea-a8c8-4818-b995-40e0d240e3fc', E'Накоплением гликогена в гепатоцитах', E'3'),
  (E'f71092e4-6cc1-46e3-8390-891aeb2024af', E'd5092a77-c826-4581-8899-360e5bbf2626', E'На 5–10%', E'0'),
  (E'b0d02ea6-0f21-4e7e-ad2b-4728f1d4a813', E'd5092a77-c826-4581-8899-360e5bbf2626', E'На 10–19%', E'1'),
  (E'c2665811-d0fb-4b5a-99ed-40b9254bd8c7', E'd5092a77-c826-4581-8899-360e5bbf2626', E'На 20–29%', E'2'),
  (E'1e46db6a-240e-42b6-9fd4-0ff5fe042aef', E'd5092a77-c826-4581-8899-360e5bbf2626', E'На 50–99%', E'3'),
  (E'5cfb7c48-336b-4ccc-b80e-377f6d401a79', E'64cfd88c-db39-439e-b605-f01535eccb5f', E'Уменьшение размера адипоцитов', E'0'),
  (E'76886e51-e4bc-4745-ad1d-34fec7a700f5', E'64cfd88c-db39-439e-b605-f01535eccb5f', E'Увеличение размеров адипоцитов и количества триглицеридов в них', E'1'),
  (E'dc9a6cac-71f4-415c-a37b-cb1419c7304d', E'64cfd88c-db39-439e-b605-f01535eccb5f', E'Полное исчезновение жировых депо', E'2'),
  (E'eb29eec0-5666-471d-9e8f-5e2ae28d6b4a', E'64cfd88c-db39-439e-b605-f01535eccb5f', E'Отложение амилоида в адипоцитах', E'3'),
  (E'c1286b43-14b3-4a7c-9732-1012cf87ceb9', E'4a319d9b-ea6c-46ae-9065-6e7162069f35', E'Накопление амилоидного вещества в тканях', E'0'),
  (E'ff4c93e6-a640-41b8-b5d8-f113b2f94aa2', E'4a319d9b-ea6c-46ae-9065-6e7162069f35', E'Накопление жира только в гепатоцитах', E'1'),
  (E'd3c9bb4f-9b68-4fdd-a7f1-c9680346bfb1', E'4a319d9b-ea6c-46ae-9065-6e7162069f35', E'Поверхностное набухание основного вещества', E'2'),
  (E'ff4a9832-42c5-4030-9bc8-85b7f0aec08c', E'4a319d9b-ea6c-46ae-9065-6e7162069f35', E'Отложение кальция в стенке аорты', E'3'),
  (E'798d4e37-8ed6-4974-94f9-23bc93da74ef', E'89889342-995f-4823-9143-8bd42de745b6', E'SAA — белок острой фазы', E'0'),
  (E'5cc008e5-70d1-4bf1-b5e6-55526850a877', E'89889342-995f-4823-9143-8bd42de745b6', E'Кератин', E'1'),
  (E'34c8e2dd-3df0-469d-85a1-40ac005311db', E'89889342-995f-4823-9143-8bd42de745b6', E'Гемоглобин', E'2'),
  (E'009d995c-6e7f-486b-8fa0-16660aac522e', E'89889342-995f-4823-9143-8bd42de745b6', E'Коллаген IV типа', E'3'),
  (E'b5254a66-c004-4ab8-b8bc-97808e4a5702', E'75962d2f-db31-4d5b-9e51-a24ed128161c', E'Амилоид откладывается преимущественно по ходу ретикулярных волокон и базальных мембран', E'0');
INSERT INTO public.question_options (id, question_id, option_text, sort_order) VALUES
  (E'9d7e3b48-0791-4757-979f-0df2b5d17443', E'75962d2f-db31-4d5b-9e51-a24ed128161c', E'Амилоид располагается только по ходу крупных коллагеновых пучков кожи', E'1'),
  (E'45bc92cb-58cb-4bf9-9b4f-e0576085f304', E'75962d2f-db31-4d5b-9e51-a24ed128161c', E'Амилоид накапливается только внутри ядер', E'2'),
  (E'e8659fb6-2c91-4117-b258-a1be7e28e3d6', E'75962d2f-db31-4d5b-9e51-a24ed128161c', E'Амилоид образуется исключительно в костной ткани', E'3'),
  (E'a1ac0c84-c85d-4a9d-918c-25f15e3fc4d3', E'f1cd0bc5-ef2a-49b4-841f-c26a1a55850b', E'Адвентиция сосудов среднего и крупного калибра, миокард, мышцы, нервы и кожа', E'0'),
  (E'316f350e-6e0f-4496-8f54-6f9e191ec970', E'f1cd0bc5-ef2a-49b4-841f-c26a1a55850b', E'Только клубочки почек', E'1'),
  (E'81da43a4-a104-441b-a02c-35916b3933ca', E'f1cd0bc5-ef2a-49b4-841f-c26a1a55850b', E'Только фолликулы селезенки', E'2'),
  (E'794f84d1-e25a-4d80-9f8e-ef45b194d3f5', E'f1cd0bc5-ef2a-49b4-841f-c26a1a55850b', E'Только базальные мембраны кишечных желез', E'3'),
  (E'15805a4a-87ce-4b24-8150-fefe8fd7355c', E'd8caa10c-41cd-48e3-9590-76380fe4dd9d', E'Саговая и сальная селезенка', E'0'),
  (E'16d3a1e2-d32e-4d85-9b5f-e1b91a14f2a9', E'b3d001ad-ee9e-4ab5-9a21-882dd9048d9a', E'Неизбежное превращение в фибринозное воспаление', E'2'),
  (E'0ebbc064-07ff-44d3-987b-40567df9b314', E'b3d001ad-ee9e-4ab5-9a21-882dd9048d9a', E'Всегда развитие распространённого некроза', E'3'),
  (E'2fded867-d1f1-4203-b3ff-dd68e4810266', E'dc70bec6-e9da-45a1-9996-d5c77aefa539', E'Выход фибриногена в ткани с последующим превращением в фибрин', E'0'),
  (E'3f9b4c05-f8cc-4533-ba82-18ef6600f3ea', E'dc70bec6-e9da-45a1-9996-d5c77aefa539', E'Преимущественное накопление прозрачной жидкости без белковых компонентов', E'1'),
  (E'd16d2670-277f-4f70-919c-178aff265e47', E'dc70bec6-e9da-45a1-9996-d5c77aefa539', E'Массивное размножение фибробластов без экссудации', E'2'),
  (E'279f297f-c9d9-42e8-a36b-b9f84d408918', E'dc70bec6-e9da-45a1-9996-d5c77aefa539', E'Изолированное скопление эритроцитов вследствие разрыва сосудов', E'3'),
  (E'a48db48e-5534-4c9a-8498-e932054fd2dd', E'bcca9260-ca21-4f9c-812b-e1448e24e8f4', E'Фибрин глубоко проникает в некротизированную слизистую и отделяется с дефектом ткани', E'0'),
  (E'0e70e587-f243-423f-bb1c-76825bd35687', E'bcca9260-ca21-4f9c-812b-e1448e24e8f4', E'Формируется ограниченная полость, заполненная гноем', E'1'),
  (E'8f064100-012e-4c9b-bf34-1a0709af4593', E'bcca9260-ca21-4f9c-812b-e1448e24e8f4', E'Фибринозный экссудат располагается преимущественно поверхностно и сравнительно легко отделяется', E'2'),
  (E'e9e94e36-2cdd-4fe0-b3c4-cc1cd76422a3', E'bcca9260-ca21-4f9c-812b-e1448e24e8f4', E'Эпителий покрывается слизью без существенного повреждения', E'3'),
  (E'86a8dbaa-88ea-414a-8ed5-910eaecec9f4', E'a335d01f-6158-41fa-8bcc-8542022a7f67', E'Тонкий поверхностный слой фибрина, легко снимающийся без дефекта', E'0'),
  (E'd618f0c6-f8d4-4f5f-a7f7-66db7402494d', E'a335d01f-6158-41fa-8bcc-8542022a7f67', E'Скопление серозной жидкости в полости без некроза', E'1'),
  (E'751d6aac-c818-4c20-b66b-1bcea4097978', E'a31c1e7e-a759-4208-8ec4-40a5c55d0e22', E'В стенках артерий и клапанах сердца', E'0'),
  (E'1ff29ad1-e45e-4a49-b42f-521f044e8b75', E'a31c1e7e-a759-4208-8ec4-40a5c55d0e22', E'В базальных мембранах клубочков почек', E'1'),
  (E'371dc7c3-fd2e-4c55-bc21-906d9150fd5d', E'a31c1e7e-a759-4208-8ec4-40a5c55d0e22', E'В цитоплазме гепатоцитов', E'2'),
  (E'f1adcae4-dbc6-4800-b39c-a0480fb3d18f', E'a31c1e7e-a759-4208-8ec4-40a5c55d0e22', E'В адипоцитах подкожной клетчатки', E'3'),
  (E'2063fad5-86ee-419e-b993-f600be13a555', E'771afc28-0cac-41ee-be56-062e09b7064f', E'Фибриноидный некроз с последующим гиалинозом', E'0'),
  (E'f9c63347-d0c6-4dd5-951e-a603c74c4b78', E'771afc28-0cac-41ee-be56-062e09b7064f', E'Полное восстановление во всех случаях', E'1'),
  (E'4f5787e3-ac53-4ee3-ab94-43adc45c25d0', E'771afc28-0cac-41ee-be56-062e09b7064f', E'Образование жировой кисты печени', E'2'),
  (E'9de10718-d8f2-45e3-ac2e-5552ef216369', E'771afc28-0cac-41ee-be56-062e09b7064f', E'Переход в гидропическую дистрофию', E'3'),
  (E'9fde0c26-8812-4b24-8726-8fdc6b57b77e', E'0f094078-4297-4209-b19e-5216d4dfa3ed', E'Простой гиалин', E'0'),
  (E'098b8455-524c-44ca-9537-5a36571d1c9f', E'0f094078-4297-4209-b19e-5216d4dfa3ed', E'Амилоид типа AA', E'1'),
  (E'efbed8d4-5c94-40f4-948e-3423f1179bd0', E'0f094078-4297-4209-b19e-5216d4dfa3ed', E'Кератогиалин', E'2'),
  (E'56960ac4-220e-4b25-8a84-b1fb67e989ae', E'0f094078-4297-4209-b19e-5216d4dfa3ed', E'Коллоид щитовидной железы', E'3'),
  (E'c47d3c46-7b8b-4e99-ba9d-14379f55eb08', E'08015b62-adc7-4904-b55e-03dac689d054', E'Для тяжелых иммунопатологических заболеваний', E'0'),
  (E'9f109449-94ae-4310-a089-8698702cbd18', E'08015b62-adc7-4904-b55e-03dac689d054', E'Для гипертонической болезни вследствие пропитывания сосудистой стенки плазмой', E'1'),
  (E'f4135865-9254-4a79-815c-356375063041', E'08015b62-adc7-4904-b55e-03dac689d054', E'При хроническом воспалении с отложением AA-амилоида', E'2'),
  (E'dd12d9d1-7306-4d13-90e5-4ad8a451c7b9', E'08015b62-adc7-4904-b55e-03dac689d054', E'При сахарном диабете вследствие накопления липидов в мелких сосудах', E'3'),
  (E'8595cf68-4ab1-4a1d-9217-e7b1574f8e18', E'a55c95dd-b473-45df-be46-06afb4a42dc4', E'20–29%', E'0'),
  (E'a228d0be-c4f0-477a-ac2f-f41af934f089', E'a55c95dd-b473-45df-be46-06afb4a42dc4', E'30–49%', E'1'),
  (E'd8a4f2bb-f2ba-469b-9e40-cbc780dd5f5b', E'a55c95dd-b473-45df-be46-06afb4a42dc4', E'50–99%', E'2'),
  (E'4b8285ef-7341-40a7-8730-640382556bef', E'a55c95dd-b473-45df-be46-06afb4a42dc4', E'100% и более', E'3'),
  (E'e33bc775-b575-41a9-b32c-6cc1ca04ee1b', E'fcb6bd47-f1dc-4837-b132-5954db0b35a1', E'Гиперпластический тип, при котором увеличивается число адипоцитов', E'0'),
  (E'e35ccb02-a950-4b5a-b5a7-564efb5e78a8', E'fcb6bd47-f1dc-4837-b132-5954db0b35a1', E'Гипертрофический тип, при котором увеличивается размер адипоцитов', E'1'),
  (E'9b39bf63-bb99-41a8-9d7a-b41b25b851a8', E'fcb6bd47-f1dc-4837-b132-5954db0b35a1', E'Андроидный тип, при котором жир преимущественно откладывается в области живота', E'2'),
  (E'a40220ef-2cec-4cb9-82c3-0414906b8525', E'fcb6bd47-f1dc-4837-b132-5954db0b35a1', E'Гиноидный тип, при котором жир преимущественно откладывается в области бёдер и ягодиц', E'3'),
  (E'b2fd4b1f-d6c0-4fff-8a39-7a258f25f4b9', E'cb53035d-d67c-4fbe-a809-d4889c707d51', E'Острый, подострый и хронический', E'0'),
  (E'603ef47f-73d0-485b-b6c9-acce95b982cd', E'cb53035d-d67c-4fbe-a809-d4889c707d51', E'Первичный, наследственный, вторичный и старческий', E'1'),
  (E'7e73cd57-ebd8-483d-8478-a44df52d257b', E'cb53035d-d67c-4fbe-a809-d4889c707d51', E'Гиперпластический и гипертрофический', E'2'),
  (E'31f40521-474b-4e71-be8a-5b77ae223ce8', E'cb53035d-d67c-4fbe-a809-d4889c707d51', E'Простой и сложный', E'3'),
  (E'bf49fc9b-1ff2-44e3-86a5-d7f09d4fdae7', E'77b2cb71-c0bc-41ea-8308-5803aec7f955', E'Почки', E'0'),
  (E'0bd48520-1cd1-472b-bc4e-1e40ddba2f3a', E'77b2cb71-c0bc-41ea-8308-5803aec7f955', E'Щитовидная железа во всех случаях', E'1'),
  (E'628135a1-a504-490b-8254-d757d6275544', E'77b2cb71-c0bc-41ea-8308-5803aec7f955', E'Кожа только', E'2'),
  (E'9b0abad4-2a5e-4e5a-986c-aeb3f8f15c84', E'77b2cb71-c0bc-41ea-8308-5803aec7f955', E'Хрусталик глаза', E'3'),
  (E'c73e3a8d-6704-4989-a0d4-a14b9d841673', E'011f5e5f-f311-4640-a96a-a504aa502022', E'Печень, почки, селезенка, надпочечники и кишечник', E'0'),
  (E'fac9b740-b430-441b-a400-43542ec6b842', E'011f5e5f-f311-4640-a96a-a504aa502022', E'Только миокард и скелетные мышцы', E'1'),
  (E'1b280215-8e99-434d-8477-30f1e82cb00b', E'011f5e5f-f311-4640-a96a-a504aa502022', E'Только кожа и периферические нервы', E'2'),
  (E'affcb035-3d82-4c04-b711-ad3208664422', E'011f5e5f-f311-4640-a96a-a504aa502022', E'Только суставные хрящи', E'3'),
  (E'b3f9aff6-00f9-401e-8853-612eb88a68e1', E'6ae38780-25df-4643-a72d-ef663003e47c', E'Усиление функции пораженного органа', E'0'),
  (E'4e80f80e-09b9-4a31-a7ec-8f164fecb409', E'6ae38780-25df-4643-a72d-ef663003e47c', E'Вытеснение и замещение паренхимы с развитием хронической функциональной недостаточности', E'1'),
  (E'0205e215-3878-458d-a299-848fc84f20aa', E'6ae38780-25df-4643-a72d-ef663003e47c', E'Полное восстановление органа независимо от степени поражения', E'2'),
  (E'dd2f3132-65a4-459e-a611-c4c65360c826', E'6ae38780-25df-4643-a72d-ef663003e47c', E'Изолированное повышение числа адипоцитов', E'3'),
  (E'3ed5d1a4-a5f0-4f5d-8121-b4abc21df0a3', E'aa1adc4c-56a0-4c22-b615-5f625e96e256', E'Симметричное, верхнее (андроидное) и нижнее (гиноидное)', E'1'),
  (E'e4410953-116f-47ff-952b-7b857cf80f15', E'aa1adc4c-56a0-4c22-b615-5f625e96e256', E'Первичное, вторичное и наследственное', E'2'),
  (E'2ae1a381-7aca-4c30-8e4c-234364246d90', E'aa1adc4c-56a0-4c22-b615-5f625e96e256', E'Периретикулярное и периколлагеновое', E'3'),
  (E'742a0152-b9a4-48f7-ac6b-c4050a9f1818', E'5e3d92ed-94c4-4e90-86d3-80422112c4ee', E'Он возникает как осложнение хронических инфекций, гнойно-деструктивных и некоторых опухолевых или ревматических заболеваний', E'0'),
  (E'd3e998d8-b63c-444a-921b-c94aa3f6ee68', E'5e3d92ed-94c4-4e90-86d3-80422112c4ee', E'Он всегда является врожденным', E'1'),
  (E'a7a3ddec-7e9b-4410-bae7-c24c1681fb19', E'5e3d92ed-94c4-4e90-86d3-80422112c4ee', E'Он развивается только в головном мозге', E'2'),
  (E'2d3e4090-b5fe-4e47-beb7-275cb08b65ce', E'5e3d92ed-94c4-4e90-86d3-80422112c4ee', E'Он не связан с предшествующими заболеваниями', E'3'),
  (E'eb2995f3-6b47-4d68-9c32-aadc04a3f7e0', E'd273b617-20e6-42fc-b4b1-1a5cd521f3fa', E'Почки становятся плотными, увеличенными и сальными; возможно амилоидное сморщивание', E'0'),
  (E'013c7ee8-1d81-47b9-98c2-cb037c86706c', E'd273b617-20e6-42fc-b4b1-1a5cd521f3fa', E'Почки всегда уменьшаются без изменения структуры', E'1'),
  (E'ebb63c6c-2c7f-4e87-9e1a-c1edd503b717', E'd273b617-20e6-42fc-b4b1-1a5cd521f3fa', E'Возникает только жировая инфильтрация эпителия', E'2'),
  (E'37d67a1b-9934-43a8-8b09-a571fdb1b41f', E'd273b617-20e6-42fc-b4b1-1a5cd521f3fa', E'Амилоид откладывается исключительно в лоханке', E'3'),
  (E'67940c4b-798c-428e-b2be-f0693c48726a', E'7323da51-8ddd-4448-aeb6-eaf786a66e64', E'Амилоид выпадает по ходу коллагеновых волокон', E'0'),
  (E'a97a89dd-1350-4be3-b481-9ee99c5edcba', E'7323da51-8ddd-4448-aeb6-eaf786a66e64', E'Амилоид образуется только в просвете канальцев', E'1'),
  (E'b320da77-be05-4dd9-b74b-0bedc330bdd3', E'7323da51-8ddd-4448-aeb6-eaf786a66e64', E'Амилоид заменяет только эпителий кишечника', E'2'),
  (E'9c6b7a47-504f-4743-b3ba-d66d97a691a3', E'7323da51-8ddd-4448-aeb6-eaf786a66e64', E'Амилоид является внутриклеточным жиром', E'3'),
  (E'8e709e95-c7d7-45fc-8c61-c0c64b1f9a4c', E'ec18de1f-dc3f-4b2b-b520-77979be02f73', E'Печень уменьшена, сухая и зернистая', E'0'),
  (E'1b94e998-acf4-4b1f-9dc6-c20482f9df8c', E'ec18de1f-dc3f-4b2b-b520-77979be02f73', E'Печень увеличена, плотная, сальным видом', E'1'),
  (E'b36c948b-a9ec-4677-b3f1-8555adf58732', E'ec18de1f-dc3f-4b2b-b520-77979be02f73', E'Печень всегда имеет зеленый цвет', E'2'),
  (E'05698911-0090-4fb9-ae05-980cdf112f48', E'ec18de1f-dc3f-4b2b-b520-77979be02f73', E'Печень превращается в полость, заполненную жиром', E'3'),
  (E'564b022e-96b6-4984-a032-585dc2b0dd07', E'a335d01f-6158-41fa-8bcc-8542022a7f67', E'Слизистый экссудат с большим количеством бокаловидных клеток', E'2'),
  (E'f2590215-45e0-4353-8072-2a64e0c89b4a', E'a335d01f-6158-41fa-8bcc-8542022a7f67', E'Глубокий некроз ткани с формированием плотно связанной фибринозной плёнки', E'3'),
  (E'cac2c76d-533c-4dd5-96ae-9299f01a7456', E'0464d2a6-d87d-46d0-b353-8f587bfd5c0b', E'Только количество эритроцитов в крови', E'0'),
  (E'1cdd9d17-b512-41d5-97e1-71621503a0a2', E'0464d2a6-d87d-46d0-b353-8f587bfd5c0b', E'Глубина некроза и особенности строения ткани в месте воспаления', E'1'),
  (E'00c7f42b-e420-4c7e-a07d-d61aad11306d', E'0464d2a6-d87d-46d0-b353-8f587bfd5c0b', E'Исключительно возраст пациента', E'2'),
  (E'd536d041-971e-4467-8c0d-168bfc6ef018', E'0464d2a6-d87d-46d0-b353-8f587bfd5c0b', E'Только наличие лимфатических узлов рядом с очагом', E'3'),
  (E'56cb154d-ad94-41b1-877d-895e1d304c44', E'afd63cf0-739c-4dc5-b074-27e5b41d2432', E'Обструкция дыхательных путей фибринозными плёнками и отёком', E'0'),
  (E'2c4d8af2-5abd-49f3-b329-744d81a1c4d1', E'62af2f62-fcac-48bf-8618-5c18d44125d4', E'Вариант ответа 1', E'0'),
  (E'6fbc983d-b23d-49da-8a42-9209903fe698', E'62af2f62-fcac-48bf-8618-5c18d44125d4', E'Вариант ответа 2', E'1'),
  (E'01ecb5b4-e0b3-4181-9ac7-d2e7ecc79ad6', E'62af2f62-fcac-48bf-8618-5c18d44125d4', E'Вариант ответа 3', E'2'),
  (E'5b772eb9-3883-4aae-8e75-045366005052', E'62af2f62-fcac-48bf-8618-5c18d44125d4', E'Вариант ответа 4', E'3'),
  (E'e4089c67-ed72-4f67-a81c-12d6b1557330', E'd8caa10c-41cd-48e3-9590-76380fe4dd9d', E'Только бурая атрофия', E'1'),
  (E'd6e56253-dd3d-497e-b60f-9fb4ff64f3eb', E'd8caa10c-41cd-48e3-9590-76380fe4dd9d', E'Только казеозный некроз', E'2'),
  (E'250b9147-ca14-4194-b3c7-067371369f6c', E'd8caa10c-41cd-48e3-9590-76380fe4dd9d', E'Только гидропическая дистрофия', E'3'),
  (E'218a7943-188a-4245-b828-f2a07a0f8bf4', E'c7a7cb27-38d6-45a3-8650-52dfa395a233', E'Вариант ответа 1', E'0'),
  (E'88992732-ce97-4a89-a4a7-d8dfa1371f90', E'c7a7cb27-38d6-45a3-8650-52dfa395a233', E'Вариант ответа 2', E'1'),
  (E'fa528847-2f5a-40c9-bc98-9aaa4d9510d1', E'c7a7cb27-38d6-45a3-8650-52dfa395a233', E'Вариант ответа 3', E'2'),
  (E'cbdefd83-96ad-4876-be26-f4d5d280ed3f', E'c7a7cb27-38d6-45a3-8650-52dfa395a233', E'Вариант ответа 4', E'3'),
  (E'640f005b-0548-4fc0-88ed-31d42b8e60a6', E'555a0746-4c91-41e9-8642-c11eb5c4699b', E'Любое увеличение числа клеток без повреждения ткани', E'0'),
  (E'a15465fa-802c-4025-a064-4d4b7fdc82eb', E'555a0746-4c91-41e9-8642-c11eb5c4699b', E'Типовая защитно-приспособительная реакция на повреждение, направленная на устранение причины и восстановление ткани', E'1'),
  (E'7c477613-1f3f-457c-b4db-b2919cf5ab98', E'555a0746-4c91-41e9-8642-c11eb5c4699b', E'Только местное кровоизлияние вследствие разрыва сосудов', E'2');
INSERT INTO public.question_options (id, question_id, option_text, sort_order) VALUES
  (E'468877e7-ce3b-4fb2-b630-fd96b6945a9c', E'555a0746-4c91-41e9-8642-c11eb5c4699b', E'Исключительно иммунная реакция без участия сосудов', E'3'),
  (E'dbf4f789-5452-4657-940f-18d8a3c8aa7d', E'49a2c3cd-c224-4b7f-ba07-70a59919933b', E'Серозное, фибринозное, гнойное, геморрагическое и катаральное экссудативное воспаление', E'0'),
  (E'97ca7735-2eaf-412f-8625-863a7f3726f2', E'49a2c3cd-c224-4b7f-ba07-70a59919933b', E'Только острое и хроническое воспаление', E'1'),
  (E'398efad6-9751-4cf8-b6d9-0f708eea05d7', E'49a2c3cd-c224-4b7f-ba07-70a59919933b', E'Первичное, вторичное и третичное воспаление', E'2'),
  (E'952efa3f-8269-4cf4-8398-75f9f526f3f8', E'49a2c3cd-c224-4b7f-ba07-70a59919933b', E'Очаговое, диффузное и системное воспаление', E'3'),
  (E'74865601-f4a1-4b98-a560-abbb49335f7f', E'63c2b95e-58fa-4b11-a0bb-c576e6dd5b90', E'По течению — серозное и гнойное; по распространённости — острое и хроническое', E'0'),
  (E'f52b8f97-9abb-4a7e-9401-3e768b692eb6', E'63c2b95e-58fa-4b11-a0bb-c576e6dd5b90', E'По течению — местное и общее; по распространённости — фибринозное и катаральное', E'1'),
  (E'e9027f43-4896-4410-ad7e-d96ece697f5e', E'63c2b95e-58fa-4b11-a0bb-c576e6dd5b90', E'По течению — острое, подострое и хроническое; по распространённости — очаговое и диффузное', E'2'),
  (E'57056ad8-1389-4a7e-be41-7a7af3db2ba4', E'63c2b95e-58fa-4b11-a0bb-c576e6dd5b90', E'Обе классификации включают только острое и хроническое воспаление', E'3'),
  (E'0295235a-3f29-4f31-8c8a-53df8f0bb48a', E'f15f9045-1b8f-4f43-8c42-01b43e1a0c4e', E'Массивное скопление гноя с тканевым расплавлением', E'0'),
  (E'9d330b94-d3be-4880-b7fb-3c3d87554d86', E'f15f9045-1b8f-4f43-8c42-01b43e1a0c4e', E'Образование плотных фибриновых плёнок на поверхности', E'1'),
  (E'9b9c4e1f-fc77-48d0-b4a4-f55138535614', E'f15f9045-1b8f-4f43-8c42-01b43e1a0c4e', E'Преобладание эритроцитов в экссудате с выраженным кровоизлиянием', E'2'),
  (E'a1d610d3-23b6-4f47-a4fc-2619225b1928', E'f15f9045-1b8f-4f43-8c42-01b43e1a0c4e', E'Образование экссудата с относительно небольшим количеством белка и клеток, преимущественно нейтрофилов или слущенных клеток', E'3'),
  (E'12ecaa46-cd8e-4baf-93d6-dce7de9fd4c4', E'b3d001ad-ee9e-4ab5-9a21-882dd9048d9a', E'Обязательное образование абсцесса', E'0'),
  (E'a4da5951-61fc-43b2-944b-5ebb93398908', E'b3d001ad-ee9e-4ab5-9a21-882dd9048d9a', E'Резорбция экссудата и восстановление ткани; при длительном течении возможно уплотнение или организация', E'1'),
  (E'7eb8c2be-7a4e-4324-8d38-e5ba367ec0c7', E'afd63cf0-739c-4dc5-b074-27e5b41d2432', E'Обязательное формирование амилоидоза', E'1'),
  (E'628b0b18-8804-44f0-ae99-6c8e1ea6df40', E'afd63cf0-739c-4dc5-b074-27e5b41d2432', E'Развитие жировой дистрофии миокарда', E'2'),
  (E'13596f13-cda1-4538-948f-5efd988832e4', E'afd63cf0-739c-4dc5-b074-27e5b41d2432', E'Изолированное накопление серозной жидкости в суставе', E'3'),
  (E'd6405c25-8e49-4de1-84af-2f7b622f0dd3', E'a78d3f32-3fcd-45fa-a57d-a0c93e2cdffe', E'Только фибриновые нити и плазменные белки', E'0'),
  (E'81d1a65d-0f7c-4db0-8ea5-cffd3e063cef', E'a78d3f32-3fcd-45fa-a57d-a0c93e2cdffe', E'Преимущественно эритроциты без лейкоцитов', E'1'),
  (E'4eaafae9-3ee2-4e1d-ba06-af811c66bc75', E'a78d3f32-3fcd-45fa-a57d-a0c93e2cdffe', E'Нейтрофильные лейкоциты, тканевой детрит и микроорганизмы, если инфекция гнойная', E'2'),
  (E'4a26411d-2947-4913-853a-5f0282605a5e', E'a78d3f32-3fcd-45fa-a57d-a0c93e2cdffe', E'Только лимфоциты и плазматические клетки', E'3'),
  (E'1739269e-a426-4591-90bc-11e443d0f1c7', E'68512e93-cfbb-42f4-93ef-355d3250fe31', E'Диффузное гнойное пропитывание клетчатки без чётких границ', E'0'),
  (E'1af95717-8908-4106-b842-005b488a2a42', E'68512e93-cfbb-42f4-93ef-355d3250fe31', E'Скопление гноя в уже существующей анатомической полости', E'1'),
  (E'fba1f7ce-a047-4620-b84a-864daad15268', E'68512e93-cfbb-42f4-93ef-355d3250fe31', E'Поверхностное скопление серозной жидкости под эпидермисом', E'2'),
  (E'b60a4f90-593d-4387-97f3-e1ac17c805d1', E'68512e93-cfbb-42f4-93ef-355d3250fe31', E'Ограниченная полость в ткани, заполненная гноем и окружённая зоной воспалительной реакции', E'3'),
  (E'f4e02dec-9674-479b-8d57-54fe2788b48e', E'78c03a9f-670a-4b31-8cde-2bcc41045a48', E'Всегда имеется хорошо отграниченная полость с пиогенной мембраной', E'0'),
  (E'9877d26c-dccc-4828-8792-6b8af0df07aa', E'78c03a9f-670a-4b31-8cde-2bcc41045a48', E'Гнойное воспаление диффузно распространяется по межтканевым пространствам и не имеет чёткой капсулы', E'1'),
  (E'2e300c7d-a79a-410c-9486-8d451a1e6364', E'78c03a9f-670a-4b31-8cde-2bcc41045a48', E'Экссудат состоит только из фибрина', E'2'),
  (E'5ba2ca6a-404e-4fa5-bd36-8461d7192435', E'78c03a9f-670a-4b31-8cde-2bcc41045a48', E'Воспаление ограничивается поверхностным эпителием', E'3'),
  (E'cad0bf41-8994-4a88-955a-a3d8d42acea1', E'741265a2-7c88-4506-8106-25bfcac5d33e', E'Накопление гноя в существующей анатомической полости', E'0'),
  (E'd85a0284-72bf-4961-a7bd-f91206609d93', E'741265a2-7c88-4506-8106-25bfcac5d33e', E'Ограниченная полость гноя, возникшая в толще ткани', E'1'),
  (E'5c6951f5-f747-4563-b18f-e512d2f5dbd9', E'741265a2-7c88-4506-8106-25bfcac5d33e', E'Диффузное гнойное пропитывание клетчатки', E'2'),
  (E'346d8181-11f0-437e-9165-a36ad9b5cd43', E'741265a2-7c88-4506-8106-25bfcac5d33e', E'Выход фибриногена с образованием плёнки на слизистой', E'3'),
  (E'6248b288-ed5e-40ae-89ef-f388cf999e8b', E'1d25fced-af0f-428d-a084-bf47ed8b91c2', E'Обязательное превращение в дифтеритическое воспаление', E'0'),
  (E'e3131aff-b4b6-464b-bcbb-3060bdfd8b08', E'1d25fced-af0f-428d-a084-bf47ed8b91c2', E'Неизбежное распространение гноя по всему организму', E'1'),
  (E'c606222f-5ffa-414d-945f-9371a3744a53', E'1d25fced-af0f-428d-a084-bf47ed8b91c2', E'Очищение очага с последующим заживлением, нередко через грануляционную ткань и рубец', E'2'),
  (E'c549e3f3-9564-45bd-9908-450c9025ca59', E'1d25fced-af0f-428d-a084-bf47ed8b91c2', E'Всегда полное восстановление без какого-либо повреждения ткани', E'3'),
  (E'c24bf594-eedd-4cf6-bf3c-2426b0e08505', E'013eee9b-17b8-4d73-98cd-1780499ae56c', E'Накопление гноя в замкнутой полости', E'0'),
  (E'978ca946-11b4-4ea4-be72-9f3c9b04c6da', E'013eee9b-17b8-4d73-98cd-1780499ae56c', E'Выпадение плотных фибриновых масс с глубоким некрозом', E'1'),
  (E'fb1469c0-abdf-4958-8cff-5762dc16bbb7', E'013eee9b-17b8-4d73-98cd-1780499ae56c', E'Массивное пропитывание ткани эритроцитами', E'2'),
  (E'b8b7a9ca-3971-446a-b225-5a4ea9ce68b6', E'013eee9b-17b8-4d73-98cd-1780499ae56c', E'Образование слизистого экссудата на поверхности слизистой оболочки', E'3'),
  (E'e7e423c8-d860-4ba1-9856-cb793f184cc5', E'f2cbee0f-d3eb-4890-b2ab-36fe49c8140f', E'Обязательное образование гиалиновых мембран в альвеолах', E'0'),
  (E'33fcbfd4-5e16-4e38-afd5-7261155f7203', E'f2cbee0f-d3eb-4890-b2ab-36fe49c8140f', E'Гиперсекреция слизи и слущивание эпителиальных клеток', E'1'),
  (E'aa1dbaee-b967-4776-b844-3edc970befb8', E'f2cbee0f-d3eb-4890-b2ab-36fe49c8140f', E'Только коагуляционный некроз всей толщины слизистой', E'2'),
  (E'cd7d27c9-999e-4c4e-aa6d-2253c5864521', E'f2cbee0f-d3eb-4890-b2ab-36fe49c8140f', E'Формирование плотной капсулы вокруг гнойной полости', E'3'),
  (E'7850d611-cb22-4add-9258-a8367cb82acb', E'3eb828c7-d9c4-42c3-b86e-1547fbaccc05', E'Выраженной примесью эритроцитов в экссудате вследствие тяжёлого повреждения сосудов', E'0'),
  (E'fd7e8eea-b9fa-45fe-aa4e-2ff0a36a8fec', E'3eb828c7-d9c4-42c3-b86e-1547fbaccc05', E'Преобладанием только слизи на поверхности слизистой', E'1'),
  (E'5a3c90cb-f15e-4123-a098-37f6e1c1be71', E'3eb828c7-d9c4-42c3-b86e-1547fbaccc05', E'Образованием исключительно стерильной серозной жидкости', E'2'),
  (E'cf07cfcc-fe5c-42ff-94d9-c51abfa4a24e', E'3eb828c7-d9c4-42c3-b86e-1547fbaccc05', E'Наличием гноя без повреждения микроциркуляторного русла', E'3'),
  (E'7491d4b8-6499-48f2-bf30-d74acf48fc6f', E'1ff307ce-fbe2-4426-80f2-371ae44e3ca2', E'Снижение проницаемости сосудов и удержание всех белков в кровотоке', E'0'),
  (E'8e5be559-a100-4d24-be27-313852776023', E'1ff307ce-fbe2-4426-80f2-371ae44e3ca2', E'Исключительное усиление деления фибробластов', E'1'),
  (E'eeccf857-b9ac-4532-9c79-518d9ad909a6', E'1ff307ce-fbe2-4426-80f2-371ae44e3ca2', E'Повышение проницаемости микрососудов с выходом жидкости и белков плазмы в ткань', E'2'),
  (E'cf36ee99-c9f2-469a-8f2f-cf0d288f58e7', E'1ff307ce-fbe2-4426-80f2-371ae44e3ca2', E'Уменьшение кровотока без изменений сосудистой стенки', E'3'),
  (E'264a0883-3ac9-4d72-8ef2-c08df946815a', E'5d8115ad-6144-4a56-8854-aa8d1e23fcdd', E'Полное восстановление эпителия без повреждения подлежащей ткани', E'0'),
  (E'd5f48c4b-4607-4a91-9d88-080e2c89e10c', E'5d8115ad-6144-4a56-8854-aa8d1e23fcdd', E'Формирование только серозного выпота в полости', E'1'),
  (E'cc467d44-31d5-4725-954a-5c1f8e0baf49', E'5d8115ad-6144-4a56-8854-aa8d1e23fcdd', E'Обязательное отложение амилоида в стенках сосудов', E'2'),
  (E'bef89f02-972c-4ea3-aa52-765fb5777c4f', E'5d8115ad-6144-4a56-8854-aa8d1e23fcdd', E'Некроз и утрата участка слизистой с образованием язвенного дефекта', E'3'),
  (E'b82b33a2-b98e-4450-937c-67905636dd5e', E'71626e9a-92ed-41e0-902d-b4b945f6ba36', E'При любом кратковременном серозном выпоте независимо от повреждения', E'0'),
  (E'059eeb85-6f28-4c11-bbf1-834c2b165f90', E'71626e9a-92ed-41e0-902d-b4b945f6ba36', E'Когда повреждение разрушило значительный объём ткани и её исходная структура не может быть полностью восстановлена', E'1'),
  (E'f5b403ad-de52-4352-9817-38f9b8b7d62a', E'71626e9a-92ed-41e0-902d-b4b945f6ba36', E'Только при катаральном воспалении слизистых', E'2'),
  (E'12771ba1-3b89-4d37-a6db-59742cc9cdcf', E'71626e9a-92ed-41e0-902d-b4b945f6ba36', E'Когда воспалительный очаг состоит исключительно из обратимых сосудистых реакций', E'3'),
  (E'f48e2e81-98da-4748-b32a-6b43ba0366f4', E'825dd8f7-77c4-48fd-804b-2aa359f0bf0a', E'Устранение повреждающего фактора, удаление экссудата и клеточного детрита с восстановлением ткани без значимого рубца', E'0'),
  (E'aa4aed61-cd9e-4a71-be30-b964a22d8929', E'825dd8f7-77c4-48fd-804b-2aa359f0bf0a', E'Замещение всего очага плотной соединительной тканью', E'1'),
  (E'f9586647-72a7-4567-bb1a-0dadcbbf5080', E'825dd8f7-77c4-48fd-804b-2aa359f0bf0a', E'Сохранение возбудителя и переход процесса в хронический', E'2'),
  (E'aa7ed587-7f24-42bc-ba6d-099aa54117a9', E'825dd8f7-77c4-48fd-804b-2aa359f0bf0a', E'Распространение воспаления на соседние органы', E'3'),
  (E'5ee701cd-644d-444f-9374-e0dc3cb2fcf5', E'f93361b3-00db-41fc-b91a-d591bb23ec85', E'Быстрое устранение причины и полное удаление экссудата', E'0'),
  (E'3ef861e9-9b4e-4520-9e2a-982a2e92be6d', E'f93361b3-00db-41fc-b91a-d591bb23ec85', E'Незначительное кратковременное расширение сосудов без повреждения ткани', E'1'),
  (E'b4d3bcca-34f0-497b-86fc-9bee895dbda0', E'f93361b3-00db-41fc-b91a-d591bb23ec85', E'Сохранение повреждающего агента или длительно существующего тканевого повреждения', E'2'),
  (E'cd26b493-6e1f-41d2-a94a-a702b80408ad', E'f93361b3-00db-41fc-b91a-d591bb23ec85', E'Полное восстановление клеток и межклеточного вещества', E'3'),
  (E'4ee8296f-8321-4f3e-850f-be454a8b0fb9', E'5ffe055d-64ea-485c-a103-c7edd230a219', E'Экссудат обязательно превращается в гной', E'0'),
  (E'181212de-5fbe-4011-8b3c-0ab988feb37e', E'5ffe055d-64ea-485c-a103-c7edd230a219', E'Все воспалительные клетки исчезают без участия репаративных механизмов', E'1'),
  (E'7e118ff8-3dac-430b-b5d8-5b7624807244', E'5ffe055d-64ea-485c-a103-c7edd230a219', E'Ткань полностью восстанавливается независимо от глубины повреждения', E'2'),
  (E'c36b278a-2adc-437a-876d-0d778205d047', E'5ffe055d-64ea-485c-a103-c7edd230a219', E'Экссудат постепенно замещается разрастающейся соединительной тканью, что может приводить к спайкам или рубцам', E'3'),
  (E'4d04057a-85ff-4a5f-a372-627fc31f305e', E'bc6b97d3-8040-4dbd-94e2-698280416a42', E'Плазматические клетки', E'0'),
  (E'5f971284-9845-4ee9-9059-349d4d198715', E'bc6b97d3-8040-4dbd-94e2-698280416a42', E'Нейтрофилы', E'1'),
  (E'67efc784-5e0a-4067-9225-b4cc9f5b7f3d', E'bc6b97d3-8040-4dbd-94e2-698280416a42', E'Фибробласты', E'2'),
  (E'c985200a-9835-4802-901e-0743e2df42c6', E'bc6b97d3-8040-4dbd-94e2-698280416a42', E'Эпителиоидные клетки гранулёмы', E'3'),
  (E'af46c8a4-b63e-4896-8fab-1d445597f2dc', E'9f0821d4-dd6a-4e7d-9493-4f3da6aac63e', E'Поверхность плевры покрыта фибриновыми наложениями, которые при организации могут привести к спайкам', E'0'),
  (E'351db64d-760b-4640-b29e-236bd9a5e0c3', E'9f0821d4-dd6a-4e7d-9493-4f3da6aac63e', E'Плевральная полость обязательно заполняется только гноем', E'1'),
  (E'b73c854e-c887-4187-8666-54e32e022df1', E'9f0821d4-dd6a-4e7d-9493-4f3da6aac63e', E'Эпителий бронхов продуцирует слизистый экссудат, формируя катар', E'2'),
  (E'815056bb-ff16-4280-a8b3-c4fe731c6e68', E'9f0821d4-dd6a-4e7d-9493-4f3da6aac63e', E'В ткани лёгкого формируется ограниченная полость с гноем', E'3'),
  (E'520313b2-9695-48d9-bb71-0113a3197896', E'4160d486-8c72-44d9-b0ac-31b325160c1b', E'Транссудат всегда содержит больше нейтрофилов, чем экссудат', E'0'),
  (E'490ee7f9-3cad-4509-88e5-817e3c7dcf44', E'4160d486-8c72-44d9-b0ac-31b325160c1b', E'Экссудат образуется только после разрыва крупной артерии', E'1'),
  (E'e9230d97-a1c3-4a59-89f1-7df8a311d506', E'4160d486-8c72-44d9-b0ac-31b325160c1b', E'Экссудат обычно богаче белком и клетками из-за воспалительного повышения сосудистой проницаемости', E'2'),
  (E'7e25cf1d-b5f5-4d78-b6db-5324591bb879', E'4160d486-8c72-44d9-b0ac-31b325160c1b', E'Между ними нет различий по составу и механизму образования', E'3'),
  (E'b4c0b82c-6955-4f05-86c1-4e85f1d43374', E'1258eabd-4aad-4766-85b4-73c7947f1f46', E'У детей воспаление всегда протекает исключительно серозно', E'0'),
  (E'd07e4504-f1de-4f9b-8cd4-0e287ee110fa', E'1258eabd-4aad-4766-85b4-73c7947f1f46', E'У детей нейтрофильная реакция никогда не развивается', E'1'),
  (E'4990f906-666f-4412-b76e-15a6d9765be4', E'1258eabd-4aad-4766-85b4-73c7947f1f46', E'У детей исход воспаления всегда ограничивается полным разрешением', E'2'),
  (E'aec64ef4-8d44-495d-8eaa-60fb173934a0', E'1258eabd-4aad-4766-85b4-73c7947f1f46', E'Клинические и морфологические проявления зависят от возраста, зрелости иммунной системы и особенностей тканей', E'3'),
  (E'0850da0b-f7ea-4b06-b268-c69ff7763bf4', E'6f7fc23f-827f-4160-9f4a-46f43f3e4318', E'Потому что у детей полностью отсутствуют сосудистые реакции', E'0'),
  (E'3bc8db85-f9db-4ea5-8b71-ad478d26e409', E'6f7fc23f-827f-4160-9f4a-46f43f3e4318', E'Из-за возрастных особенностей иммунной защиты и барьерных механизмов, а также меньших функциональных резервов организма', E'1'),
  (E'9f6e6519-69ef-4c2c-9df0-180b9f36dba6', E'6f7fc23f-827f-4160-9f4a-46f43f3e4318', E'Потому что воспалительный экссудат у детей не содержит белков', E'2'),
  (E'ed686086-b8f8-4f29-8c3d-3c6aa5f62714', E'6f7fc23f-827f-4160-9f4a-46f43f3e4318', E'Потому что фибринозное воспаление у детей невозможно', E'3'),
  (E'736404fd-c1f3-43be-9d83-dcd8fcd0ceda', E'd1e8c900-e317-4601-a6b0-552e75e5f069', E'Образование спаек, способных нарушать подвижность органов или проходимость кишечника', E'0'),
  (E'585cc96b-d6b5-4f66-9499-59cddbc182fb', E'd1e8c900-e317-4601-a6b0-552e75e5f069', E'Обязательное развитие эмпиемы плевры', E'1'),
  (E'cfbe47e1-b302-47d5-ba71-ff83e11d4fe6', E'd1e8c900-e317-4601-a6b0-552e75e5f069', E'Формирование катарального воспаления бронхов', E'2'),
  (E'42d0b95a-4cb8-4b09-8803-920f07c5190e', E'd1e8c900-e317-4601-a6b0-552e75e5f069', E'Полное исчезновение фибрина без возможности фиброза в любом случае', E'3'),
  (E'a2540f06-384e-4cea-a5f5-aa9e13dd587a', E'7b28ac3e-70b8-4f5e-83b8-74f16b7c8f01', E'Они исключительно образуют фибрин из фибриногена', E'0'),
  (E'cdf77547-d752-4d5e-bfec-3baf9c81dd34', E'7b28ac3e-70b8-4f5e-83b8-74f16b7c8f01', E'Они являются единственными клетками, вызывающими сосудистое расширение', E'1');
INSERT INTO public.question_options (id, question_id, option_text, sort_order) VALUES
  (E'e2b49a97-f721-463a-8f1e-a99506c0e303', E'7b28ac3e-70b8-4f5e-83b8-74f16b7c8f01', E'Они поглощают клеточный детрит и погибшие клетки, участвуют в регуляции воспаления и запуске репарации', E'2'),
  (E'3bba800e-9161-4c46-ab8d-55150af9c2b7', E'7b28ac3e-70b8-4f5e-83b8-74f16b7c8f01', E'Они препятствуют удалению экссудата и всегда поддерживают хронизацию', E'3'),
  (E'9bb3626c-0a59-4cd4-a73f-db8633b41c1a', E'd14771f9-7927-4fc6-89ae-6a8ed6d09cf9', E'Обязательное формирование глубокого рубца', E'0'),
  (E'a0ff3589-2a57-4c93-b068-20ad001b6d65', E'd14771f9-7927-4fc6-89ae-6a8ed6d09cf9', E'Неизбежное превращение в абсцесс', E'1'),
  (E'33acdbea-ce31-44b6-84f4-e0c2ff169a3f', E'7e04afcf-11c4-4fce-a076-f0e6c38903dc', E'Вариант ответа 1', E'0'),
  (E'562c5bf9-911e-4617-966d-62e72071f602', E'd14771f9-7927-4fc6-89ae-6a8ed6d09cf9', E'Организация экссудата в массивные спайки серозных оболочек', E'2'),
  (E'33ee4ab2-eb37-450d-ae68-34ca0832f7a0', E'd14771f9-7927-4fc6-89ae-6a8ed6d09cf9', E'Удаление слизистого экссудата и восстановление эпителия', E'3'),
  (E'8cac4af0-ba80-4d89-bd18-84a784e258f0', E'6ed6c634-83a1-4f01-8b79-1bad5440dc72', E'Кратковременное расширение сосудов без повреждения клеток', E'0'),
  (E'bef0ca55-23ac-423c-a693-bca33acf768a', E'6ed6c634-83a1-4f01-8b79-1bad5440dc72', E'Обширный некроз с утратой тканевой структуры и выраженным клеточным детритом', E'1'),
  (E'b3778217-13a6-4232-b50e-faa4cf0ea7e9', E'6ed6c634-83a1-4f01-8b79-1bad5440dc72', E'Небольшое количество прозрачного экссудата при сохранной архитектуре', E'2'),
  (E'f3206269-3d64-4de8-8a40-bf17ee4eb94e', E'6ed6c634-83a1-4f01-8b79-1bad5440dc72', E'Изолированное усиление секреции слизи без слущивания эпителия', E'3'),
  (E'3bdcd4c5-2b1c-4027-8d73-04a74ed0b636', E'88abbdfc-722d-41dc-a1ad-251e2befdec8', E'Объём повреждения, сохранность тканевого каркаса и способность клеток к регенерации', E'0'),
  (E'35727db0-1004-4565-ab40-e491e62d9963', E'88abbdfc-722d-41dc-a1ad-251e2befdec8', E'Только цвет экссудата', E'1'),
  (E'42c3cce7-e388-4e45-817c-81ac2ca79bf3', E'88abbdfc-722d-41dc-a1ad-251e2befdec8', E'Только наличие лихорадки', E'2'),
  (E'6441c415-6446-4132-b649-13250c9782db', E'88abbdfc-722d-41dc-a1ad-251e2befdec8', E'Исключительно количество жидкости в сосудистом русле', E'3'),
  (E'd1a49ff4-a093-47ee-bc49-bbe2ade8f0e4', E'19f9b670-955f-4ee1-bfeb-d652d59d202e', E'Серозное — исключительно эритроцитарный; фибринозное — слизистый; гнойное — малобелковый транссудат', E'0'),
  (E'608d200f-5f45-44a1-ae46-bda30a57e833', E'19f9b670-955f-4ee1-bfeb-d652d59d202e', E'Катаральное — гной в замкнутой полости; геморрагическое — только фибрин', E'1'),
  (E'4e465b6e-f4e4-4e70-8d91-e6dc27a23a1c', E'19f9b670-955f-4ee1-bfeb-d652d59d202e', E'Серозное — жидкий; фибринозное — богатый фибрином; гнойное — нейтрофильный с тканевым детритом', E'2'),
  (E'e3af529f-ec14-487d-9a65-4220c2b648a3', E'19f9b670-955f-4ee1-bfeb-d652d59d202e', E'Гнойное — преимущественно фибробласты; серозное — некротическая плёнка', E'3'),
  (E'6b66616c-1854-4a52-bb91-e08e612b4887', E'e25cba46-6d7b-43a7-af0f-3f36ab917dff', E'Преобладание экссудации плазмы с формированием отека', E'0'),
  (E'9919de7e-19c4-4935-a168-e983536d04ea', E'e25cba46-6d7b-43a7-af0f-3f36ab917dff', E'Преобладание клеточной пролиферации и образования клеточных инфильтратов с последующим разрастанием соединительной ткани', E'1'),
  (E'b40325b2-e474-42a6-933f-e5f9e5e39fbc', E'e25cba46-6d7b-43a7-af0f-3f36ab917dff', E'Обязательное образование гнойной полости, ограниченной капсулой', E'2'),
  (E'063d28c7-a280-418b-9d70-caf3507b048d', E'e25cba46-6d7b-43a7-af0f-3f36ab917dff', E'Преимущественное накопление фибрина на поверхности серозных оболочек', E'3'),
  (E'b5d2be42-2f2b-4319-a46f-6e7127bfff99', E'c61c1f78-51a7-4c01-aae5-1ca0228c7f65', E'Интерстициальное, гранулематозное и воспаление с образованием полипов и остроконечных кондилом', E'0'),
  (E'2104a39e-d696-47e6-ba7a-3352a12866b3', E'c61c1f78-51a7-4c01-aae5-1ca0228c7f65', E'Серозное, фибринозное, гнойное и геморрагическое', E'1'),
  (E'051e5107-8141-4113-adef-86e34a1d5469', E'c61c1f78-51a7-4c01-aae5-1ca0228c7f65', E'Катаральное, крупозное и дифтеритическое', E'2'),
  (E'169f991e-8669-4d0c-8405-89e55604b379', E'c61c1f78-51a7-4c01-aae5-1ca0228c7f65', E'Артериальное, венозное и лимфатическое', E'3'),
  (E'727d3bc2-0d8a-4d69-bafe-b17e4dbe77e9', E'16c310d9-26b4-4f84-a9a8-3b036f6d2272', E'Полное восстановление миокарда за счет массового деления кардиомиоцитов', E'0'),
  (E'b40bdb8e-c25d-414c-a50d-a5940f2e5a31', E'16c310d9-26b4-4f84-a9a8-3b036f6d2272', E'Формирование диффузного мелкоочагового кардиосклероза', E'1'),
  (E'2a8fd6f9-67f0-432e-8578-33ac58ddcf2e', E'16c310d9-26b4-4f84-a9a8-3b036f6d2272', E'Образование множественных казеозных гранулем', E'2'),
  (E'8edd9eee-1231-4556-a131-e0ca2b3abb24', E'16c310d9-26b4-4f84-a9a8-3b036f6d2272', E'Развитие гнойного расплавления с формированием эмпиемы', E'3'),
  (E'3573bcac-08bd-4a3c-915b-b769e15be5f3', E'9a6a8fa5-1bbf-457b-99a8-09f20054f792', E'Кратковременное воздействие раздражителя, полностью удаляемого нейтрофилами', E'0'),
  (E'dcf3d2b5-506b-4167-bee0-1dc0108acf52', E'9a6a8fa5-1bbf-457b-99a8-09f20054f792', E'Стойкость возбудителя или другого раздражителя по отношению к фагоцитам и невозможность его быстрого устранения', E'1'),
  (E'000b43e6-eedc-4f7f-9365-7d31c6ba2f71', E'9a6a8fa5-1bbf-457b-99a8-09f20054f792', E'Изолированное повышение проницаемости сосудов без клеточной реакции', E'2'),
  (E'7870c648-2eee-4d60-a28f-65d8cfebf294', E'9a6a8fa5-1bbf-457b-99a8-09f20054f792', E'Обязательное предшествующее образование фибринозной пленки', E'3'),
  (E'a1db9a14-a06d-4c1a-9203-efc5aa12d8f3', E'4b9d6f7d-0399-4514-9fbd-98f1a042f6a2', E'Это типичная морфология туберкулезной гранулемы, хотя дифференциальная диагностика все равно учитывает клинические и лабораторные данные', E'0'),
  (E'32d20be9-81f8-4994-8a3c-351d6d26b453', E'4b9d6f7d-0399-4514-9fbd-98f1a042f6a2', E'Это специфический признак саркоидоза, для которого характерен обширный казеозный некроз', E'1'),
  (E'59fe260b-b0db-4131-aa74-b10fbb02fb0e', E'4b9d6f7d-0399-4514-9fbd-98f1a042f6a2', E'Это типичная лепроматозная гранулема с многочисленными клетками Вирхова', E'2'),
  (E'be1354b3-5b7d-406e-89ab-74cc58cf2510', E'4b9d6f7d-0399-4514-9fbd-98f1a042f6a2', E'Это неспецифический полип слизистой оболочки, построенный из железистого эпителия', E'3'),
  (E'381bf01f-d97e-4d18-b764-f3a1683273de', E'a65e0736-1c1a-45ac-afb9-ce920b2ae6d0', E'Нейтрофилы, формирующие сплошной слой гнойного экссудата', E'0'),
  (E'b12099d0-4cda-4d6c-8799-a61fe4a70141', E'a65e0736-1c1a-45ac-afb9-ce920b2ae6d0', E'Моноцитарные фагоциты, в том числе макрофаги и их эпителиоидные производные', E'1'),
  (E'59be6415-b9c3-4ada-b407-c8948b50729b', E'a65e0736-1c1a-45ac-afb9-ce920b2ae6d0', E'Эритроциты, пропитывающие строму без клеточной реакции', E'2'),
  (E'b8c43bb2-3a9b-40af-922a-c462c076d486', E'a65e0736-1c1a-45ac-afb9-ce920b2ae6d0', E'Только фибробласты в зрелом коллагеновом рубце', E'3'),
  (E'37a3aed7-648f-4004-ae4d-8311a391d8b4', E'2666195e-8025-44ad-9f5d-ec042bd6e6da', E'Инфильтрат и пролиферативные изменения преимущественно располагаются в строме органа', E'0'),
  (E'9e70fdc3-8daa-4135-8e03-0b6cbd0eb13f', E'2666195e-8025-44ad-9f5d-ec042bd6e6da', E'Повреждение обязательно ограничено эпителием слизистой оболочки', E'1'),
  (E'fd4b159d-aba0-403e-85c6-fea0731d3761', E'2666195e-8025-44ad-9f5d-ec042bd6e6da', E'В ткани всегда присутствуют крупные участки казеозного некроза', E'2'),
  (E'6288b6e2-6fec-487b-8dcb-93413ab28a79', E'2666195e-8025-44ad-9f5d-ec042bd6e6da', E'Воспаление не сопровождается повреждением функциональных клеток', E'3'),
  (E'395bd40e-c0bc-4930-84eb-61fdc01376d5', E'099a5601-3d2f-45e2-bfbc-c2049ab4b1bd', E'Полное исчезновение воспалительных клеток без изменения межклеточного вещества', E'0'),
  (E'8c598bdf-7d78-4fdb-94db-cfa6c6f9b987', E'099a5601-3d2f-45e2-bfbc-c2049ab4b1bd', E'Активация фибробластов и усиленное образование компонентов внеклеточного матрикса при хроническом повреждении', E'1'),
  (E'a34df0ce-2807-40bd-a2e4-b87df2839213', E'099a5601-3d2f-45e2-bfbc-c2049ab4b1bd', E'Изолированное накопление нейтрофилов с быстрым гнойным расплавлением ткани', E'2'),
  (E'd3a7afa1-f3ca-47b7-a601-49793462759a', E'099a5601-3d2f-45e2-bfbc-c2049ab4b1bd', E'Превращение всех макрофагов непосредственно в гепатоциты', E'3'),
  (E'94b7b401-1c60-4a1e-a912-709b9fe89c43', E'cbebfd8a-b4f9-4dfd-a47d-f2e268e0190d', E'Центральный казеозоподобный некроз, лимфоплазмоцитарный инфильтрат, фибробласты и продуктивный эндоваскулит с формированием капсулы', E'0'),
  (E'9e6af592-21ec-48b7-bd3a-3d7616953899', E'cbebfd8a-b4f9-4dfd-a47d-f2e268e0190d', E'Обильные клетки Вирхова, заполненные микобактериями лепры', E'1'),
  (E'8352da14-d524-473d-bdab-92aa670fd68c', E'cbebfd8a-b4f9-4dfd-a47d-f2e268e0190d', E'Компактные неказеозные эпителиоидные гранулемы без выраженного сосудистого компонента', E'2'),
  (E'9ad729fb-2156-4f0e-acd4-857748f3c977', E'cbebfd8a-b4f9-4dfd-a47d-f2e268e0190d', E'Преимущественно нейтрофильный экссудат в полости, выстланной мезотелием', E'3'),
  (E'57db9d7b-a926-44af-89a6-55b37cbf810c', E'05dffe5d-e133-4a28-af1a-573bd894720f', E'Туберкулоидной форме, при которой возбудители обычно обнаруживаются редко', E'0'),
  (E'0a2cc6fd-f88c-4874-9b96-a3291fb3be84', E'05dffe5d-e133-4a28-af1a-573bd894720f', E'Лепроматозной форме, при которой микобактерии накапливаются в клетках и образуют лепрозные шары', E'1'),
  (E'685d8cb1-1d4d-4d80-8b31-1a80905dcf16', E'05dffe5d-e133-4a28-af1a-573bd894720f', E'Саркоидозе, где клетки Вирхова являются диагностическим признаком', E'2'),
  (E'7ae83ded-4a11-461d-bac7-3317b9b4dd68', E'05dffe5d-e133-4a28-af1a-573bd894720f', E'Третичном сифилисе, где они формируют сосудистую капсулу гуммы', E'3'),
  (E'26552ec7-12cf-4f93-8394-a3bbcdea253e', E'9bf79719-2d94-49ef-bc48-fb44beb7440c', E'Эпителиоидно-клеточные гранулемы без выраженного казеозного некроза', E'0'),
  (E'1338b8b4-5b9f-4c09-8c11-1b5e5c4d9ee0', E'9bf79719-2d94-49ef-bc48-fb44beb7440c', E'Центральный обширный казеозный некроз и многочисленные микобактерии в клетках Вирхова', E'1'),
  (E'a425e5bf-bdc4-48c3-9ba5-3d43492abb65', E'9bf79719-2d94-49ef-bc48-fb44beb7440c', E'Гуммозный некроз с плазматическими клетками и продуктивным эндоваскулитом', E'2'),
  (E'2efdf6f0-cd1b-402a-9435-1bd2ee0d29f0', E'9bf79719-2d94-49ef-bc48-fb44beb7440c', E'Сплошной нейтрофильный экссудат с формированием гнойной полости', E'3'),
  (E'35a6418d-602e-498c-80e5-5ee11d045b3c', E'eadc289f-e846-4a79-8ebe-e197eefd7b29', E'Слияние активированных макрофагов при длительной стимуляции трудноустранимым агентом', E'0'),
  (E'550471ac-ae9a-494d-91d3-18c1c05530b3', E'eadc289f-e846-4a79-8ebe-e197eefd7b29', E'Деление зрелых коллагеновых волокон на отдельные ядра', E'1'),
  (E'bcb90f6c-90e8-4696-b556-f4bc13375dc5', E'eadc289f-e846-4a79-8ebe-e197eefd7b29', E'Выход эритроцитов из сосудов с последующей фрагментацией ядер', E'2'),
  (E'd367e40b-a05b-49d8-a6a1-d21e04315cfd', E'eadc289f-e846-4a79-8ebe-e197eefd7b29', E'Превращение нейтрофилов в фибробласты после завершения фагоцитоза', E'3'),
  (E'04a345c5-5308-4607-bf97-f30fa0c22779', E'0fd22f99-1b3f-45fd-b8ff-bc05d2622188', E'Обязательное образование крупной гнойной полости без рубцевания', E'0'),
  (E'99486a23-b3ce-4edd-bdcc-d5944fb1f860', E'0fd22f99-1b3f-45fd-b8ff-bc05d2622188', E'Формирование небольшого соединительнотканного рубчика; иногда возможно обызвествление', E'1'),
  (E'1a73aabc-87a4-40c1-a5c2-c0fb85c65835', E'0fd22f99-1b3f-45fd-b8ff-bc05d2622188', E'Всегда полное восстановление исходной ткани без следа', E'2'),
  (E'edf56110-96bc-4351-aa3a-8b807c622825', E'0fd22f99-1b3f-45fd-b8ff-bc05d2622188', E'Образование клеток Вирхова и распространение микобактерий лепры', E'3'),
  (E'd3d285bf-8903-4e88-8651-ec85d9b34a23', E'f045e6fa-9792-40f5-abdf-26bb4405cbb9', E'Он имеет диффузный характер, обычно не содержит центрального казеозного некроза и поражает стенку аорты, распространяясь по vasa vasorum', E'0'),
  (E'6695adfe-a27b-43e4-bc14-661f6c50cf52', E'f045e6fa-9792-40f5-abdf-26bb4405cbb9', E'Он состоит исключительно из нейтрофилов и формирует эмпиему в просвете аорты', E'1'),
  (E'343f303e-f168-4ce1-8546-ccd40a5d47b3', E'f045e6fa-9792-40f5-abdf-26bb4405cbb9', E'Он всегда образует компактную капсулу вокруг крупного казеозного центра', E'2'),
  (E'71e37eac-b46b-47d4-a1b2-e8eba06c9d71', E'f045e6fa-9792-40f5-abdf-26bb4405cbb9', E'Он представляет собой гранулему с клетками Вирхова и микобактериями', E'3'),
  (E'74d6074d-33e9-438d-a8d1-6905be052bef', E'7b60a693-69f5-461f-be5e-b615fe33d561', E'Продуктивный васкулит vasa vasorum вызывает трофические нарушения и разрушение эластических структур средней оболочки', E'0'),
  (E'8b32df54-8bd9-4a66-86a7-17f66da9931e', E'7b60a693-69f5-461f-be5e-b615fe33d561', E'Массивное накопление фибрина на интиме механически расширяет просвет аорты', E'1'),
  (E'5396f02a-8124-4608-8837-9d333babe8a1', E'7b60a693-69f5-461f-be5e-b615fe33d561', E'Нейтрофилы полностью замещают гладкомышечные клетки без поражения сосудов стенки', E'2'),
  (E'280eb181-d101-4069-91b2-37b1324ca954', E'7b60a693-69f5-461f-be5e-b615fe33d561', E'Кальцификация клапанов приводит к обязательному разрыву аортального кольца', E'3'),
  (E'e85f2d0e-5da3-471b-aea0-d90704793367', E'228ce249-6204-4198-83f9-ba0129fb7ce1', E'Инфекционные связаны с возбудителями, сохраняющимися в ткани; неинфекционные могут возникать вокруг инертных или труднорасщепляемых материалов', E'0'),
  (E'd994b318-33c3-4b61-8210-17757bd079de', E'228ce249-6204-4198-83f9-ba0129fb7ce1', E'Инфекционные всегда лишены макрофагов, а неинфекционные состоят только из нейтрофилов', E'1'),
  (E'1f95d283-eff4-4aae-bcaa-b76914fc79e0', E'228ce249-6204-4198-83f9-ba0129fb7ce1', E'Неинфекционные гранулемы всегда содержат казеозный некроз, инфекционные — никогда', E'2'),
  (E'cdec2bb5-4cf4-48c0-b7b0-74269c168c28', E'228ce249-6204-4198-83f9-ba0129fb7ce1', E'Этиологическое деление не имеет отношения к механизму гранулематозной реакции', E'3'),
  (E'4050f5d6-d6f5-44b8-9e06-51b484608ed4', E'91c3c3bd-0145-4bd4-8003-845117226c23', E'Наличие материала в центре или среди макрофагов и гигантских клеток при реакции вокруг трудноудаляемых частиц', E'0'),
  (E'8294540f-29ca-447b-a214-ae8aa4d0a89b', E'91c3c3bd-0145-4bd4-8003-845117226c23', E'Обязательное наличие казеозного некроза и клеток Пирогова—Лангханса', E'1'),
  (E'651e72a5-269a-48b4-9290-ba9230512142', E'91c3c3bd-0145-4bd4-8003-845117226c23', E'Наличие только плазматических клеток и продуктивного эндоваскулита', E'2'),
  (E'3e00a6b0-a2b7-4db4-ab4e-afdf46260d53', E'91c3c3bd-0145-4bd4-8003-845117226c23', E'Обязательное присутствие микобактерий, выявляемых окраской по Цилю—Нильсену', E'3'),
  (E'7d8b0388-ccf5-4f04-aa2e-1c19203c7b55', E'c8eb457e-1335-45c3-9f61-3700a5d7d428', E'Группу заболеваний, в которых тканевая реакция закономерно включает образование гранулем', E'0'),
  (E'a1939807-de4b-40b7-af25-2762acaee426', E'c8eb457e-1335-45c3-9f61-3700a5d7d428', E'Любые болезни, сопровождающиеся кратковременным отеком и гиперемией', E'1'),
  (E'7ee276d3-a556-4177-8853-3f7b5c6bbb27', E'c8eb457e-1335-45c3-9f61-3700a5d7d428', E'Только заболевания, вызванные бактериями, образующими гной', E'2'),
  (E'2b0cca6e-11a2-43de-9998-0b01a0fe2bb0', E'c8eb457e-1335-45c3-9f61-3700a5d7d428', E'Исключительно опухоли из клеток моноцитарного ряда', E'3'),
  (E'c8cea4da-4e1d-474d-84e5-d66a93ac69d9', E'138785f1-be5d-4279-b935-600feffc8e1c', E'Отсутствие выявленного возбудителя не исключает инфекционную этиологию; нужны сопоставление с клиникой и дополнительные методы', E'0'),
  (E'c2d92393-815f-4eff-9cec-5d0429c22cd8', E'138785f1-be5d-4279-b935-600feffc8e1c', E'Гранулема автоматически считается саркоидозом независимо от локализации и клинических данных', E'1'),
  (E'36616d48-efd4-4378-91a2-1858114f0074', E'138785f1-be5d-4279-b935-600feffc8e1c', E'Такой клеточный состав доказывает, что процесс не связан с иммунными механизмами', E'2'),
  (E'1942d595-28d1-4ed0-8a61-d4806cac4821', E'138785f1-be5d-4279-b935-600feffc8e1c', E'Необнаружение микроорганизмов исключает гранулематозное воспаление', E'3'),
  (E'3bd80f1a-4836-4b43-a035-2dc65923d7d8', E'7e04afcf-11c4-4fce-a076-f0e6c38903dc', E'Вариант ответа 2', E'1'),
  (E'6caeb4f5-176c-4fb9-a326-5bae6cd7599e', E'7e04afcf-11c4-4fce-a076-f0e6c38903dc', E'Вариант ответа 3', E'2'),
  (E'9995ae5a-b74f-4c01-8ae1-e57f42b6c33b', E'7e04afcf-11c4-4fce-a076-f0e6c38903dc', E'Вариант ответа 4', E'3'),
  (E'41247bba-10b0-404a-8615-880df7f55288', E'8ff709ac-489b-4d05-8649-a73820088931', E'Клетки Микулича, плазматические клетки, лимфоциты и гиалиновые шары; быстрое развитие склероза может суживать просвет дыхательных путей', E'0'),
  (E'9808273b-bb74-4dc3-aaec-dcb76dacf51b', E'8ff709ac-489b-4d05-8649-a73820088931', E'Клетки Вирхова с многочисленными микобактериями и преимущественное поражение периферических нервов', E'1');
INSERT INTO public.question_options (id, question_id, option_text, sort_order) VALUES
  (E'c2e2f2fd-03b2-4839-af0b-778a6903d148', E'8ff709ac-489b-4d05-8649-a73820088931', E'Центральный казеозный некроз, клетки Пирогова—Лангханса и периферический лимфоцитарный вал', E'2'),
  (E'1d8eba89-4da1-4233-a92f-d73551ed3ba3', E'8ff709ac-489b-4d05-8649-a73820088931', E'Компактные неказеозные эпителиоидные гранулемы без склонности к фиброзу', E'3'),
  (E'd730ede9-650d-4b8f-8b73-81ae717b9a1a', E'1b29b77c-a2eb-4b6a-85ed-25a9d8b91b00', E'При лепроматозной форме много микобактерий в клетках Вирхова; при туберкулоидной — эпителиоидно-клеточные гранулемы и возбудители обнаруживаются редко', E'0'),
  (E'43f649e4-7575-4210-a446-02d1fa167ef6', E'1b29b77c-a2eb-4b6a-85ed-25a9d8b91b00', E'При лепроматозной форме всегда имеется центральный казеозный некроз, а при туберкулоидной — только гной', E'1'),
  (E'eb84fdb6-0db3-4eec-ac5f-8e9d80592f5c', E'1b29b77c-a2eb-4b6a-85ed-25a9d8b91b00', E'Обе формы морфологически идентичны и различаются только локализацией кожных очагов', E'2'),
  (E'4e221917-a68a-4cfa-8cab-f4221b8a44b6', E'1b29b77c-a2eb-4b6a-85ed-25a9d8b91b00', E'Туберкулоидная форма характеризуется клетками Микулича и гиалиновыми шарами', E'3'),
  (E'38561c6f-70f1-4872-bd0a-633fc9f75ba3', E'8c20b8b8-8cbd-4eff-bef2-b202bbf80ade', E'Он может поддерживать активацию макрофагов и формирование эпителиоидных клеток, но не всегда обеспечивает элиминацию устойчивого агента', E'0'),
  (E'090fbcc0-47a4-4740-ab08-66451aa28fe9', E'8c20b8b8-8cbd-4eff-bef2-b202bbf80ade', E'Он полностью предотвращает образование гранулем, поскольку подавляет фагоцитоз', E'1'),
  (E'd6f74d7b-092a-4cde-92fd-f88c08dcbed2', E'8c20b8b8-8cbd-4eff-bef2-b202bbf80ade', E'Он вызывает исключительно выход плазмы и не влияет на клеточный состав очага', E'2'),
  (E'f427d2f1-c5d9-497d-ba53-6700a472514f', E'8c20b8b8-8cbd-4eff-bef2-b202bbf80ade', E'Он неизменно приводит к гнойному расплавлению любой гранулемы', E'3'),
  (E'afb07406-bf26-4882-a376-a184eb91bcda', E'3b91eca2-7afe-455a-b986-8321b024b840', E'Склероз с возможной атрофией и деформацией органа', E'0'),
  (E'648fdcd6-4790-439b-9bc7-86692680bbf6', E'3b91eca2-7afe-455a-b986-8321b024b840', E'Обязательное восстановление исходной ткани без рубца', E'1'),
  (E'57812b1a-9fcc-43b7-b1a7-70cb6afb4830', E'3b91eca2-7afe-455a-b986-8321b024b840', E'Переход всех инфильтрирующих клеток в эпителиальные клетки', E'2'),
  (E'aa95ba56-d63c-497e-9728-5ed84d519b90', E'3b91eca2-7afe-455a-b986-8321b024b840', E'Формирование множественных эмболов в просветах артерий', E'3'),
  (E'a55ba53f-082b-4aa3-84aa-c4e5becd2bbe', E'65ff643f-a213-4eb0-9fa8-a8ba8497d773', E'Это может отражать одновременно продолжающееся повреждение и репаративную реакцию, при которой восстановление идет через рубцевание', E'0'),
  (E'26924ddb-fa96-44de-934c-5aa26933a81e', E'65ff643f-a213-4eb0-9fa8-a8ba8497d773', E'Это доказывает, что воспаление полностью завершилось и активных повреждений больше нет', E'1'),
  (E'1823d5d7-6681-478c-a8eb-a0a640f22d41', E'65ff643f-a213-4eb0-9fa8-a8ba8497d773', E'Это типично только для острого серозного воспаления', E'2'),
  (E'dce88c47-4629-47fb-8b7d-691f57b990b7', E'65ff643f-a213-4eb0-9fa8-a8ba8497d773', E'Это исключает участие макрофагов и цитокинов в патогенезе', E'3'),
  (E'f1edba1e-9063-4707-8e7c-05915a2dad22', E'7392f23e-6e96-48b8-b3e7-3cb7e8e67109', E'Длительное воспаление и регенераторно-пролиферативная гиперплазия слизистой с выступанием разрастания над ее поверхностью', E'0'),
  (E'8b87f088-5d01-4b06-baa2-9fc4980b5f09', E'7392f23e-6e96-48b8-b3e7-3cb7e8e67109', E'Острое кровоизлияние в подслизистую с формированием гематомы без пролиферации', E'1'),
  (E'788fe318-e849-4d43-9ae6-07a3fc1ed95e', E'7392f23e-6e96-48b8-b3e7-3cb7e8e67109', E'Изолированное отложение амилоида в стенках сосудов слизистой', E'2'),
  (E'82a9d00c-71bd-409f-aac1-fb477bcc143f', E'7392f23e-6e96-48b8-b3e7-3cb7e8e67109', E'Обязательное образование гранулем с казеозным некрозом', E'3'),
  (E'f0e49408-a057-48ae-9ad4-7604a0c59031', E'd1d8cc58-58b8-4d4b-bd95-a1298bd1dc5c', E'Папиллярные разрастания эпителия и стромы на фоне хронического воспаления, часто связанные с инфекцией вирусом папилломы человека', E'0'),
  (E'362e19f9-f9db-4deb-864e-397185e04cb0', E'd1d8cc58-58b8-4d4b-bd95-a1298bd1dc5c', E'Гнойная полость с некротическим центром и пиогенной мембраной', E'1'),
  (E'1af34142-9d04-475a-8c5a-0b64a72bf924', E'd1d8cc58-58b8-4d4b-bd95-a1298bd1dc5c', E'Диффузное отложение фибрина на серозной оболочке без клеточной пролиферации', E'2'),
  (E'a3e9ad01-c50b-4932-a0cd-2c41efc86d90', E'd1d8cc58-58b8-4d4b-bd95-a1298bd1dc5c', E'Казеозный некроз в центре гранулемы с микобактериями', E'3'),
  (E'87790f67-1a33-4600-9df5-c2c4ab0dabc4', E'870e41a6-72e6-46aa-824f-56a2f28844df', E'Сохранение повреждающего агента или устойчивого иммунного раздражения при неполном устранении причины', E'0'),
  (E'693f4c61-915f-41b1-9888-319776d56454', E'870e41a6-72e6-46aa-824f-56a2f28844df', E'Однократный кратковременный выход жидкости из сосудов без клеточной реакции', E'1'),
  (E'e31172d4-24fb-42f3-94d6-ef489cf37534', E'870e41a6-72e6-46aa-824f-56a2f28844df', E'Полное удаление причины и немедленное восстановление ткани', E'2'),
  (E'c492e561-a117-4558-8ec3-aee334596271', E'870e41a6-72e6-46aa-824f-56a2f28844df', E'Изолированное увеличение количества эритроцитов в периферической крови', E'3'),
  (E'9474f41f-4f0b-4317-a78b-2fdc5de03b46', E'b55eef05-278f-47bb-9818-d2e43154650c', E'Продуктивное воспаление с гиперпластическим полипообразованием на фоне хронического воспаления', E'0'),
  (E'8df00387-8da4-4995-80a0-ce7b134ece0d', E'b55eef05-278f-47bb-9818-d2e43154650c', E'Острое фибринозное воспаление с образованием дифтеритической пленки', E'1'),
  (E'325f9171-708d-46e1-a358-2635c28d34e9', E'b55eef05-278f-47bb-9818-d2e43154650c', E'Гнойное воспаление с формированием абсцесса', E'2'),
  (E'f197704b-071c-4807-b830-73d8f95f7278', E'b55eef05-278f-47bb-9818-d2e43154650c', E'Изолированная жировая дистрофия эпителия', E'3'),
  (E'7844a1a6-796a-4e9d-9e61-c6ef8ad41365', E'f182b2bb-a787-409b-b7e6-4b41f91d1809', E'Амилоидоз вызывает симптомы только при массивном некрозе ткани', E'3'),
  (E'a40060b7-7c19-46b8-87a4-78d86a8f3738', E'9e221404-79da-4301-aff8-a9c1a4fe5a4a', E'Организованное узелковое скопление макрофагов и их производных, часто с периферическими лимфоцитами', E'0'),
  (E'e0d4422f-c7cb-4821-ae9c-4d4f4a26dc83', E'9e221404-79da-4301-aff8-a9c1a4fe5a4a', E'Наличие любых лимфоцитов в ткани независимо от их расположения', E'1'),
  (E'4672087b-44c2-4719-9641-84069a79e731', E'9e221404-79da-4301-aff8-a9c1a4fe5a4a', E'Обязательное наличие выраженного отека без клеток', E'2'),
  (E'8f14e99e-0008-488d-8450-1fe90be3bad7', E'9e221404-79da-4301-aff8-a9c1a4fe5a4a', E'Исключительно разлитое накопление нейтрофилов в межклеточном пространстве', E'3'),
  (E'9118d3d3-13a6-4d8f-a526-ad51295ba36c', E'aea35f40-df09-464f-87b3-53054d544739', E'Одинаковый гранулематозный паттерн может возникать при разных причинах, поэтому одной морфологии иногда недостаточно для этиологического диагноза', E'0'),
  (E'89ca8025-1069-46c9-82bb-91aaf188f6db', E'aea35f40-df09-464f-87b3-53054d544739', E'Каждая гранулема имеет строго уникальную морфологию, позволяющую без дополнительных данных назвать возбудителя', E'1'),
  (E'ec2e5665-9b61-43e9-b1f2-da49d3d7929d', E'aea35f40-df09-464f-87b3-53054d544739', E'Если гранулема не содержит некроза, она не может быть инфекционной', E'2'),
  (E'5f72e113-c521-4467-987b-ac7f3718c9d5', E'aea35f40-df09-464f-87b3-53054d544739', E'Наличие гигантских клеток всегда означает инородное тело', E'3'),
  (E'5ab450c9-f262-4b01-b29e-53fddbea6c73', E'741d8e96-df45-481b-b9d3-325f94b2bc42', E'Нарушение архитектоники, атрофия функциональных элементов и снижение функции органа', E'0'),
  (E'33acc919-bd5b-4133-8975-8e80b7f0d114', E'741d8e96-df45-481b-b9d3-325f94b2bc42', E'Неограниченное восстановление исходного количества специализированных клеток без остаточных изменений', E'1'),
  (E'be8907cf-a56f-43c5-9b79-8f3a2d88e50a', E'741d8e96-df45-481b-b9d3-325f94b2bc42', E'Обязательное превращение склероза в гнойное воспаление', E'2'),
  (E'6d329d3b-9962-46ea-8373-ac97794068a5', E'741d8e96-df45-481b-b9d3-325f94b2bc42', E'Полное исчезновение внеклеточного матрикса', E'3'),
  (E'c9767241-4990-4990-b90e-58096ded6e13', E'bed3b3d8-428d-4ac2-914b-fa8c37cf3f39', E'Сохранение гранулем, некроз в части очагов, фиброз и иногда деформация пораженного органа', E'0'),
  (E'6eca86b9-7ee9-47b1-b408-4bb9cd8e81c1', E'bed3b3d8-428d-4ac2-914b-fa8c37cf3f39', E'Только кратковременный отек с обязательным полным разрешением за несколько часов', E'1'),
  (E'006e241a-cbbd-450b-90e0-066009a2799d', E'bed3b3d8-428d-4ac2-914b-fa8c37cf3f39', E'Всегда формирование эмпиемы в ближайшей естественной полости', E'2'),
  (E'0a394aea-968c-4ce8-aedc-2d27cfa71c39', E'bed3b3d8-428d-4ac2-914b-fa8c37cf3f39', E'Обязательное развитие злокачественной опухоли из эпителиоидных клеток', E'3'),
  (E'1a7604fd-4f68-4d4d-822f-521e540384a8', E'b64549c8-77a0-42fe-bb0a-302d34910c04', E'Сочетание мононуклеарного инфильтрата, повреждения ткани и репарации с фиброзом', E'0'),
  (E'e6072fdb-ffe3-4fe8-b9a3-abcaec5d9d7d', E'b64549c8-77a0-42fe-bb0a-302d34910c04', E'Преобладание только нейтрофилов без повреждения ткани и без репарации', E'1'),
  (E'4d30a58e-cbf3-44f1-a818-3250ba2dbb93', E'b64549c8-77a0-42fe-bb0a-302d34910c04', E'Обязательное отсутствие сосудистых изменений', E'2'),
  (E'669c42b8-6c43-48ee-913a-c1f5d7cfc32e', E'b64549c8-77a0-42fe-bb0a-302d34910c04', E'Исключительно кратковременное расширение артериол без клеточной реакции', E'3'),
  (E'22c2b821-fb99-4561-b79f-7f8290a331e8', E'e0e2df27-1006-4fbf-9612-7eed44406cc9', E'Он указывает на участие адаптивного иммунного ответа и мононуклеарных фагоцитов, но сам по себе не устанавливает конкретную этиологию', E'0'),
  (E'aacb5008-1e59-4469-98a8-30dec54fab4f', E'e0e2df27-1006-4fbf-9612-7eed44406cc9', E'Он специфичен только для третичного сифилиса и исключает другие причины', E'1'),
  (E'6d574f8b-189a-4151-ad67-c4ff1a4adcd7', E'e0e2df27-1006-4fbf-9612-7eed44406cc9', E'Он доказывает отсутствие тканевого повреждения и фиброза', E'2'),
  (E'3385519e-39e1-4b78-ae47-51d1e07cd748', E'e0e2df27-1006-4fbf-9612-7eed44406cc9', E'Он является морфологическим признаком исключительно острого гнойного воспаления', E'3'),
  (E'4944b36f-836b-4bb0-86cf-45aa5cf2783c', E'ab162df1-ee44-4b42-8aea-6e6d44910483', E'Гранулема, морфологический облик которой при определенных заболеваниях имеет характерные черты, позволяющие предположить конкретную этиологию', E'0'),
  (E'f2d80ce8-44ec-40c8-a5f0-65e6c58e133d', E'ab162df1-ee44-4b42-8aea-6e6d44910483', E'Любая гранулема, независимо от причины, которая обязательно содержит один и тот же возбудитель', E'1'),
  (E'575f9fd3-f8c9-4922-a4ca-a95da64a4ac6', E'ab162df1-ee44-4b42-8aea-6e6d44910483', E'Гранулема, состоящая только из нейтрофилов и гноя', E'2'),
  (E'8eefd50e-df64-4acc-86b6-31dd0e41fef8', E'ab162df1-ee44-4b42-8aea-6e6d44910483', E'Полиповидное разрастание слизистой без организованного клеточного узелка', E'3'),
  (E'84c4839c-2b35-4897-a049-3ab542d48943', E'27b610f6-dc90-4721-83f5-d6c6cb2d8762', E'Изменение состава межклеточного вещества при сохранности паренхиматозных клеток', E'2'),
  (E'ed18292e-3279-44b4-894c-6f67a04b5007', E'27b610f6-dc90-4721-83f5-d6c6cb2d8762', E'Нарушение обмена только минеральных веществ с отложением солей в тканях', E'3'),
  (E'87cebb70-8aee-4869-80f5-12ff22e9ea84', E'f92de2c3-5c00-43f7-8d9f-bbc704bd44f0', E'Желчный пигмент, образующийся при конъюгации билирубина в гепатоцитах', E'0'),
  (E'be230674-f486-4ed5-8ede-6e080e229810', E'9a29bd7c-180d-4661-9224-4f3a788ffc07', E'Вариант ответа 1', E'0'),
  (E'f68ec7a4-f663-46cf-830f-ed46e9323eb5', E'0bc4f8d3-2b3d-461b-a7e1-56ae29b80178', E'Связывание антигена с IgG и активация комплемента с отложением иммунных комплексов', E'0'),
  (E'caffd124-8026-4af3-890e-8d45ee8fb1b4', E'0bc4f8d3-2b3d-461b-a7e1-56ae29b80178', E'Перекрёстное связывание аллергеном IgE на тучных клетках с дегрануляцией', E'1'),
  (E'ba031670-3bc0-4191-87e6-1833aa163829', E'0bc4f8d3-2b3d-461b-a7e1-56ae29b80178', E'Прямое цитотоксическое действие CD8+ лимфоцитов на эндотелий', E'2'),
  (E'e4b703da-2c37-4d85-9a18-c6965764bb73', E'0bc4f8d3-2b3d-461b-a7e1-56ae29b80178', E'Образование гранулём вследствие персистенции макрофагов', E'3'),
  (E'cc3f1dc6-4941-45d4-b19d-76905a2d6629', E'a01737a6-4d53-476c-ba23-a93aaae84858', E'Отложение растворимых иммунных комплексов в клубочках', E'0'),
  (E'7b4efcb0-7be5-4eff-ace1-9a1d4260cfc0', E'a01737a6-4d53-476c-ba23-a93aaae84858', E'IgE-зависимая дегрануляция тучных клеток', E'1'),
  (E'5badd08f-8cb5-4a99-91a5-d9f5f0ae63be', E'a01737a6-4d53-476c-ba23-a93aaae84858', E'Антитела к антигенам клеточной поверхности или базальных мембран с цитотоксическим либо функциональным эффектом', E'2'),
  (E'18a8df24-cc33-4392-8357-170fa6bab344', E'a01737a6-4d53-476c-ba23-a93aaae84858', E'Сенсибилизированные T-лимфоциты, выделяющие цитокины при повторном контакте', E'3'),
  (E'c3340d2b-f8c7-42bf-b66f-0f72d51c5e1d', E'52be8585-241b-4165-8ea8-3e16335a0c10', E'I тип', E'0'),
  (E'f001b2d8-21c5-4a7d-882a-b83ae27307b2', E'52be8585-241b-4165-8ea8-3e16335a0c10', E'II тип', E'1'),
  (E'498557df-38ae-4b31-8673-cda4d4854137', E'52be8585-241b-4165-8ea8-3e16335a0c10', E'III тип', E'2'),
  (E'd619fb63-210a-4b1a-a0cc-f0a760c11c4c', E'52be8585-241b-4165-8ea8-3e16335a0c10', E'IV тип', E'3'),
  (E'454139a1-bbc1-4151-9126-3cc16f5ac099', E'1ce8fc2a-7745-4c4b-974a-fb9e81fb5893', E'Связывание IgE с Fc-рецепторами тучных клеток', E'0'),
  (E'6860a987-cbf7-4606-ba97-ea899160bb88', E'1ce8fc2a-7745-4c4b-974a-fb9e81fb5893', E'Отложение комплексов антиген–антитело в стенках сосудов', E'1'),
  (E'5f8a84bc-2d8d-4584-8d30-58f065e1f069', E'1ce8fc2a-7745-4c4b-974a-fb9e81fb5893', E'Распознавание антигена сенсибилизированными T-клетками с привлечением и активацией макрофагов', E'2'),
  (E'f2ca072b-636c-44ae-8e59-da4c1b57e9e0', E'1ce8fc2a-7745-4c4b-974a-fb9e81fb5893', E'Нейтрализация токсина антителами без тканевого повреждения', E'3'),
  (E'c2303d94-644e-44e2-b398-2cd62920ccdd', E'69a7a24b-070a-416b-abfe-952e36e33f71', E'Гиперчувствительность I типа', E'0'),
  (E'947f2236-f098-4bed-b0aa-d33c4f85aaf7', E'69a7a24b-070a-416b-abfe-952e36e33f71', E'Гиперчувствительность II типа', E'1'),
  (E'b44c91ad-f662-4f3c-92a0-d4d54128a62f', E'69a7a24b-070a-416b-abfe-952e36e33f71', E'Гиперчувствительность III типа', E'2'),
  (E'a4a1f967-001a-4fc1-b3a0-b7baa8ccc2b6', E'69a7a24b-070a-416b-abfe-952e36e33f71', E'Гиперчувствительность IV типа', E'3'),
  (E'01273dc1-ae8c-4dab-a66a-4858d8b035d8', E'3fdc5a7c-e9c0-4c56-b299-de0461865d06', E'Иммунокомплексное повреждение фолликулов щитовидной железы', E'0'),
  (E'b351572d-941b-447b-b9e5-47f85ec1bc65', E'3fdc5a7c-e9c0-4c56-b299-de0461865d06', E'Антителозависимая стимуляция рецептора без обязательного разрушения клеток', E'1'),
  (E'14294b56-afbf-46b0-964f-0a8ba6c5b069', E'3fdc5a7c-e9c0-4c56-b299-de0461865d06', E'T-клеточный цитолиз тиреоцитов как единственный механизм', E'2'),
  (E'69fde7d2-e7ea-4988-9ab9-982db80e16fe', E'3fdc5a7c-e9c0-4c56-b299-de0461865d06', E'Отложение амилоида в строме железы', E'3'),
  (E'040f03b7-69a1-420b-9c20-9a915aecae01', E'dfd0c48c-f29b-468a-91ca-87bc9c3ab8e7', E'Только блокада рецептора ТТГ аутоантителами без клеточного воспаления', E'0'),
  (E'c644dd5c-8683-42c7-8866-3d34b9325a6c', E'dfd0c48c-f29b-468a-91ca-87bc9c3ab8e7', E'Потеря иммунологической толерантности к тиреоидным антигенам с участием T-клеток и аутоантител', E'1'),
  (E'113a888e-156c-4973-9350-d32f86098864', E'dfd0c48c-f29b-468a-91ca-87bc9c3ab8e7', E'Отложение циркулирующих иммунных комплексов исключительно в капиллярах клубочков', E'2'),
  (E'a57e042b-08a2-4d0c-b942-7e99517cc811', E'dfd0c48c-f29b-468a-91ca-87bc9c3ab8e7', E'IgE-зависимая немедленная дегрануляция тучных клеток в железе', E'3'),
  (E'172295f6-b0d5-4e3f-b24e-0a674ea7ebce', E'389dc2c8-4d2e-4ca9-896c-3d5f7bc12d13', E'Антитела к ядерным антигенам, иммунокомплексное повреждение и возможный «волчаночный» нефрит', E'0'),
  (E'bb6bcedc-5185-45c7-a4cc-7f0f680ce64d', E'389dc2c8-4d2e-4ca9-896c-3d5f7bc12d13', E'Антитела к рецептору ТТГ и диффузная гиперплазия тиреоцитов', E'1'),
  (E'768f73a8-a4ac-4105-9960-d3e69855e1ab', E'389dc2c8-4d2e-4ca9-896c-3d5f7bc12d13', E'Антитела к базальной мембране лёгких и почек с линейным свечением IgG как обязательный признак', E'2'),
  (E'f16380c7-b60c-4c72-8bb4-d56b1f714dc8', E'9a29bd7c-180d-4661-9224-4f3a788ffc07', E'Вариант ответа 2', E'1'),
  (E'9ea6e61e-0a17-49c6-b167-a084d93c4e60', E'9a29bd7c-180d-4661-9224-4f3a788ffc07', E'Вариант ответа 3', E'2');
INSERT INTO public.question_options (id, question_id, option_text, sort_order) VALUES
  (E'f7fa08dd-b597-41c7-ab30-f58d9970270f', E'389dc2c8-4d2e-4ca9-896c-3d5f7bc12d13', E'Изолированный дефицит нейтрофилов без аутоантител и иммунных депозитов', E'3'),
  (E'd39cf0be-1a2a-4eb7-bc9b-3fcaa311db23', E'33571c6e-ea78-420a-9ecc-92cee3c4a304', E'Гранулярные депозиты иммуноглобулинов в клубочках и сосудах кожи', E'0'),
  (E'34e15802-63cd-42cf-a512-9eb2c4223fb6', E'33571c6e-ea78-420a-9ecc-92cee3c4a304', E'Линейное отложение IgG вдоль базальных мембран клубочковых капилляров; возможны сходные изменения в альвеолах', E'1'),
  (E'71c20501-7b35-4ba6-a408-1314bda925ba', E'33571c6e-ea78-420a-9ecc-92cee3c4a304', E'Лимфоидные фолликулы с клетками Гюртле', E'2'),
  (E'b71631bc-6fdc-489c-aa6d-fe4f9907a6c6', E'33571c6e-ea78-420a-9ecc-92cee3c4a304', E'Казеозный некроз с эпителиоидными гранулёмами', E'3'),
  (E'fe75a638-8c2d-4370-bbaa-6a2de62ced54', E'2e1ca21e-e9b0-48f0-b03a-3ee7aaecc096', E'Нарушение иммунной функции, обусловленное врождённым генетическим дефектом, хотя клинически он может проявиться позже', E'0'),
  (E'cbd0317c-ed8c-4403-809b-fa5df1fe367d', E'2e1ca21e-e9b0-48f0-b03a-3ee7aaecc096', E'Любое снижение иммунитета после химиотерапии', E'1'),
  (E'f5f3992b-022d-437f-9696-8db0c7fabdcb', E'2e1ca21e-e9b0-48f0-b03a-3ee7aaecc096', E'Иммунная реакция на собственные антигены', E'2'),
  (E'7c3f46cf-a986-472a-9c9b-f6792585cea8', E'2e1ca21e-e9b0-48f0-b03a-3ee7aaecc096', E'Избыточный синтез IgE при атопии', E'3'),
  (E'5feda9d8-ef1d-47d8-a836-4bec57852451', E'e495d31e-098e-46d8-b53b-011825fa00fc', E'Созревание или функция B-клеток и гуморальный иммунитет', E'0'),
  (E'372c656a-f7d6-4d96-9183-847d0724ac20', E'e495d31e-098e-46d8-b53b-011825fa00fc', E'Функция цитотоксических T-лимфоцитов при сохранной продукции антител', E'1'),
  (E'49ce30ea-ad62-4958-82ba-d3d806891989', E'e495d31e-098e-46d8-b53b-011825fa00fc', E'Фагоцитоз нейтрофилов при нормальных иммуноглобулинах', E'2'),
  (E'fcd12faf-2e97-40dd-85dd-7891c742728b', E'e495d31e-098e-46d8-b53b-011825fa00fc', E'Классический путь комплемента при изолированном снижении C1', E'3'),
  (E'ba3b4971-0a1f-409f-9bf6-8dd71ae493ae', E'59fe811f-1572-4f0c-ad3a-7f19f10924ba', E'Преимущественно аутоиммунный тиреоидит без инфекций', E'0'),
  (E'b0eba970-5bb4-4d16-905b-20f327817103', E'59fe811f-1572-4f0c-ad3a-7f19f10924ba', E'Тяжёлые рецидивирующие инфекции, включая оппортунистические, из-за дефекта клеточного и гуморального звеньев', E'1'),
  (E'e304000e-4528-45ce-9403-320d4630b106', E'59fe811f-1572-4f0c-ad3a-7f19f10924ba', E'Изолированный нефротический синдром вследствие AL-амилоидоза', E'2'),
  (E'afad6822-feb0-43f2-8ee2-5adbe3b20b2a', E'59fe811f-1572-4f0c-ad3a-7f19f10924ba', E'Только немедленные аллергические реакции на пищевые антигены', E'3'),
  (E'7a157192-7577-4632-b3e1-65b78141bfde', E'8102efc9-83c3-4619-814c-f25010a978c9', E'Нарушение координации клеточного и гуморального иммунного ответа с ростом риска оппортунистических инфекций', E'0'),
  (E'9e470e06-dd98-45ba-a90f-1dab357b3118', E'8102efc9-83c3-4619-814c-f25010a978c9', E'Избирательное усиление антителозависимой цитотоксичности без иных последствий', E'1'),
  (E'8a1fdb93-3520-48ee-a8a0-83e6d29e189c', E'8102efc9-83c3-4619-814c-f25010a978c9', E'Развитие исключительно иммунокомплексного васкулита', E'2'),
  (E'e8f80556-664a-46f9-8c69-b4fcdc4fc46d', E'8102efc9-83c3-4619-814c-f25010a978c9', E'Полная утрата продукции нейтрофилов в костном мозге', E'3'),
  (E'867c505a-a398-44dc-a11b-d5f197c26844', E'fb61f786-1017-456c-96ec-8c4c4896cfe9', E'Смерть преимущественно от инфекционных осложнений', E'0'),
  (E'b7b70959-ae4c-41e3-b67f-7165778c7b4d', E'fb61f786-1017-456c-96ec-8c4c4896cfe9', E'Изолированное развитие гипертиреоза вследствие стимуляции рецептора ТТГ', E'1'),
  (E'37af9e88-dcc9-48df-a33a-91e62bbf89c8', E'fb61f786-1017-456c-96ec-8c4c4896cfe9', E'Обязательное формирование системной красной волчанки', E'2'),
  (E'00d89a74-a1f3-41a8-8d32-4935211bd08f', E'fb61f786-1017-456c-96ec-8c4c4896cfe9', E'Смерть исключительно от разрыва амилоидно изменённой селезёнки', E'3'),
  (E'c74ee27d-d0d5-4c78-ba32-f676bf24c6bb', E'858ba74a-f43d-4a43-a901-423ddcabc886', E'Накопление внутриклеточных капель триглицеридов', E'0'),
  (E'ede5b4e1-0fd6-4f1f-b6d0-fcb837c3bbca', E'858ba74a-f43d-4a43-a901-423ddcabc886', E'Внеклеточное отложение неправильно свернутых фибриллярных белков с характерными тинкториальными свойствами', E'1'),
  (E'fba5cce9-236b-4d78-a12b-112b616b7cd2', E'858ba74a-f43d-4a43-a901-423ddcabc886', E'Отложение иммунных комплексов только в клубочках', E'2'),
  (E'47a019fb-1238-4171-9fef-4838c9c86516', E'858ba74a-f43d-4a43-a901-423ddcabc886', E'Избыточное образование коллагена при любом хроническом воспалении', E'3'),
  (E'72a7c9b3-5ee1-4220-ba8e-c8c945545572', E'4ef9d36d-01c9-409d-b702-f1d00d0f00b5', E'Фибриллы из лёгких цепей иммуноглобулинов, часто связанные с плазмоклеточными дискразиями', E'0'),
  (E'4a64b7e7-7627-4229-afd2-ac2b92a77048', E'4ef9d36d-01c9-409d-b702-f1d00d0f00b5', E'Фибриллы сывороточного амилоида A при длительном воспалении', E'1'),
  (E'560cddb9-6761-45b3-98ac-eb2b53f00920', E'4ef9d36d-01c9-409d-b702-f1d00d0f00b5', E'Отложение β2-микроглобулина при длительном гемодиализе', E'2'),
  (E'74d3291a-ca8a-427c-857b-567b4fc0a970', E'4ef9d36d-01c9-409d-b702-f1d00d0f00b5', E'Отложение транстиретина при наследственной мутации или старении', E'3'),
  (E'fc9c0a1b-7aee-4299-bb49-7ce921046a5f', E'1967d615-d60e-44a0-8dd1-f8ce84258120', E'Отложение амилоида в клубочках и сосудах с протеинурией, нефротическим синдромом и прогрессированием почечной недостаточности', E'0'),
  (E'12a30d9c-3027-4f61-987c-c0167588e885', E'1967d615-d60e-44a0-8dd1-f8ce84258120', E'Изолированное поражение канальцев с глюкозурией без протеинурии', E'1'),
  (E'c691699d-0412-4221-b001-85e20f4ca350', E'1967d615-d60e-44a0-8dd1-f8ce84258120', E'Казеозный некроз клубочков с формированием полостей', E'2'),
  (E'7f42bd3f-c0f2-45be-bfba-3bfb69448deb', E'1967d615-d60e-44a0-8dd1-f8ce84258120', E'Линейное отложение IgG без амилоидных масс', E'3'),
  (E'f511f54f-af9e-4a37-aa3e-a0255e95e4e4', E'59c2d1b6-5243-4a85-b1ab-ed9329d31df5', E'Печень обычно увеличена, плотная, с восковидным видом на разрезе', E'0'),
  (E'384bc03b-4df7-4af3-8e95-aa000c99f257', E'59c2d1b6-5243-4a85-b1ab-ed9329d31df5', E'Печень резко уменьшена и покрыта множественными казеозными узлами', E'1'),
  (E'5a043b7f-9f26-45fc-ad43-d2c1f1d3d132', E'59c2d1b6-5243-4a85-b1ab-ed9329d31df5', E'Поверхность печени всегда мелкозернистая вследствие цирроза', E'2'),
  (E'b89400ec-4c91-44b8-8220-6bbc0501c240', E'59c2d1b6-5243-4a85-b1ab-ed9329d31df5', E'Орган увеличен только за счёт жировых вакуолей в гепатоцитах', E'3'),
  (E'1c828ec4-da56-4b46-9132-55d13c1f7808', E'e7cfce69-a32d-4889-b5d6-59f0d7752888', E'Внеклеточные отложения в миокарде повышают его жёсткость и нарушают диастолическое наполнение', E'0'),
  (E'197e3af3-26f1-414d-92b7-de4dc42cd6bf', E'e7cfce69-a32d-4889-b5d6-59f0d7752888', E'Внутриклеточное накопление гликогена вызывает только систолический шум', E'1'),
  (E'05176543-fd81-44d2-ac9b-1a49e8abc5e6', E'e7cfce69-a32d-4889-b5d6-59f0d7752888', E'Иммунные комплексы разрушают клапаны исключительно через гранулематозное воспаление', E'2'),
  (E'78f3a990-9c08-4c40-adc1-15fd1fd36957', E'e7cfce69-a32d-4889-b5d6-59f0d7752888', E'Амилоид всегда ограничивается эпикардом и не влияет на функцию миокарда', E'3'),
  (E'58394982-40ee-446a-8dea-a9d4512fa2a4', E'11070d93-4d11-4a50-ad30-76daf424a125', E'Длительное повышение сывороточного амилоида A при хроническом воспалении', E'0'),
  (E'11c0846a-643f-49d3-a052-58f4acea69cb', E'11070d93-4d11-4a50-ad30-76daf424a125', E'Изолированная активация IgE при сезонном рините', E'1'),
  (E'd2e3bce4-eee4-40e4-9bbe-9b81e91cc904', E'11070d93-4d11-4a50-ad30-76daf424a125', E'Недостаток витамина C без воспалительной реакции', E'2'),
  (E'175d6f4e-bfce-4d80-bda3-d7941b094278', E'11070d93-4d11-4a50-ad30-76daf424a125', E'Антитела к базальной мембране клубочков', E'3'),
  (E'7fc153e4-ac83-4a7f-b198-23c649c857b6', E'0b201ff5-6e74-4264-8f1f-a73a9831922e', E'Определение белка-предшественника амилоидных фибрилл', E'0'),
  (E'749edb03-b35b-48d3-a852-b73b316ae432', E'0b201ff5-6e74-4264-8f1f-a73a9831922e', E'Только оценка массы поражённого органа', E'1'),
  (E'150c1962-da4d-49bb-905c-36a7fece1570', E'0b201ff5-6e74-4264-8f1f-a73a9831922e', E'Определение наличия лихорадки в день биопсии', E'2'),
  (E'cdc267e3-42da-43a2-936c-36e37240fcea', E'0b201ff5-6e74-4264-8f1f-a73a9831922e', E'Классификация исключительно по цвету ткани на разрезе', E'3'),
  (E'25d61447-077f-44bf-8dd6-c941375b7225', E'220f6034-a2c2-4697-b9bb-4e6c7ca2ef69', E'Анафилаксия', E'0'),
  (E'0c4be294-7c57-475a-96de-848d294f2469', E'220f6034-a2c2-4697-b9bb-4e6c7ca2ef69', E'Антителозависимая цитотоксичность', E'1'),
  (E'0c1a7402-b14c-4aad-9cb9-398afd4c6426', E'220f6034-a2c2-4697-b9bb-4e6c7ca2ef69', E'Иммунокомплексный васкулит', E'2'),
  (E'76d2ed36-ed71-4b8f-b2fb-6143aad25bb8', E'220f6034-a2c2-4697-b9bb-4e6c7ca2ef69', E'Гиперчувствительность замедленного типа', E'3'),
  (E'52e3ba00-ebf9-4b4b-8816-96059ea03a97', E'a2f1d89a-8a27-4530-a7dd-94b8bf0e1df4', E'Исход зависит от ведущего органного поражения; особенно опасны сердечная недостаточность и прогрессирующая почечная недостаточность', E'0'),
  (E'978a62ff-f78a-4b51-9dfa-aea0db8b5687', E'a2f1d89a-8a27-4530-a7dd-94b8bf0e1df4', E'Смерть всегда наступает из-за разрыва селезёнки', E'1'),
  (E'e2081e39-326c-4ec7-95a1-c62829fdbc33', E'a2f1d89a-8a27-4530-a7dd-94b8bf0e1df4', E'Амилоидоз не приводит к функциональной недостаточности органов', E'2'),
  (E'0353fdd3-9c1b-42f2-b7cb-5fa7271ed2d2', E'a2f1d89a-8a27-4530-a7dd-94b8bf0e1df4', E'Единственная причина смерти — массивная анафилаксия', E'3'),
  (E'797939c2-bbcf-4109-acf6-eb0b7c46ad34', E'f2e397a6-7c91-4cac-93a2-657b6067c283', E'I тип — иммунные комплексы; II тип — IgE; III тип — T-клетки; IV тип — антитела к клеточной поверхности', E'0'),
  (E'417a4cdb-5eb8-4a8a-a5e4-d46d615f0a89', E'f2e397a6-7c91-4cac-93a2-657b6067c283', E'I тип — IgE и тучные клетки; II тип — антитела к фиксированным антигенам; III тип — иммунные комплексы; IV тип — T-клетки', E'1'),
  (E'6061a528-b544-4bab-8063-85fa31c28b02', E'f2e397a6-7c91-4cac-93a2-657b6067c283', E'I тип — CD8+ цитолиз; II тип — иммунные комплексы; III тип — IgE; IV тип — комплемент', E'2'),
  (E'852d334b-77c6-400b-a20c-0d1ea1181642', E'f2e397a6-7c91-4cac-93a2-657b6067c283', E'I тип — гранулёмы; II тип — фиброз; III тип — амилоид; IV тип — некроз', E'3'),
  (E'd72b2d1f-c627-47a9-9661-7c26192aecf9', E'3d168020-a5d4-4f22-8fb5-e8f8d2370971', E'Хроническая стимуляция синтеза SAA привела к AA-амилоидозу с преимущественным поражением клубочков', E'0'),
  (E'4ec03808-f204-4826-b6d7-df4c241353ae', E'3d168020-a5d4-4f22-8fb5-e8f8d2370971', E'Аутоантитела к рецептору ТТГ вызвали отложение коллагена в клубочках', E'1'),
  (E'fd6c5298-23b5-4a65-990a-48b264d9d64b', E'3d168020-a5d4-4f22-8fb5-e8f8d2370971', E'IgE-индуцированная дегрануляция тучных клеток сформировала амилоидные фибриллы', E'2'),
  (E'1801ebf4-8353-4afa-8aee-bb41565536d4', E'3d168020-a5d4-4f22-8fb5-e8f8d2370971', E'Дефицит CD4+ клеток непосредственно превращает иммуноглобулины в амилоид', E'3'),
  (E'224bfe09-c3cb-4a91-8377-16d6a8146696', E'3a1991dd-8147-4090-92c6-629b10a22708', E'По одной окраске гематоксилином и эозином можно окончательно установить AL-тип', E'0'),
  (E'31b1c774-d5e5-4979-bb14-0f2696bc2a6e', E'3a1991dd-8147-4090-92c6-629b10a22708', E'Наличие материала требует подтверждения специальной окраской и, по возможности, определения типа амилоидного белка', E'1'),
  (E'e1a4ccce-6bcd-4ffd-9f8d-ec407c391663', E'3a1991dd-8147-4090-92c6-629b10a22708', E'Любой эозинофильный внеклеточный материал является амилоидом', E'2'),
  (E'c1d3bce2-a102-4c6c-8dd0-d2f367eaf8a4', E'3a1991dd-8147-4090-92c6-629b10a22708', E'Морфологическое исследование не имеет значения при диагностике амилоидоза', E'3'),
  (E'd9c93142-e722-4b1c-bfa3-50612651db13', E'650dd3e8-a68e-490e-aac0-18791bee1faa', E'Эти состояния полностью взаимоисключают друг друга', E'0'),
  (E'06482f94-8128-4a5a-beb6-a37013655239', E'650dd3e8-a68e-490e-aac0-18791bee1faa', E'При некоторых иммунодефицитах нарушения регуляции иммунитета могут сочетаться с аутоиммунными проявлениями', E'1'),
  (E'e584b165-67f7-4bf2-8991-b0166222a142', E'650dd3e8-a68e-490e-aac0-18791bee1faa', E'Аутоиммунитет всегда обусловлен отсутствием всех иммуноглобулинов', E'2'),
  (E'8a1cea21-69b5-4b96-9d5d-4e2634660744', E'650dd3e8-a68e-490e-aac0-18791bee1faa', E'Иммунодефицит означает исключительно повышенную реактивность тучных клеток', E'3'),
  (E'40069420-4080-481e-948f-d6b34fb73ec2', E'570e7423-0453-4926-aba2-1da8d57f1dfc', E'Тканевая инфильтрация T-лимфоцитами с макрофагальной активацией и повреждением клеток-мишеней', E'0'),
  (E'fdbaa78e-ac8e-47c8-a6df-b45a07ffff0f', E'570e7423-0453-4926-aba2-1da8d57f1dfc', E'Гранулярные депозиты иммуноглобулинов и C3 в стенках сосудов', E'1'),
  (E'265c49c7-b11f-446e-bd5c-8677ffb7063e', E'570e7423-0453-4926-aba2-1da8d57f1dfc', E'Линейное свечение IgG вдоль базальной мембраны', E'2'),
  (E'7549f905-6424-4184-af22-d6fbae48a92b', E'570e7423-0453-4926-aba2-1da8d57f1dfc', E'Немедленный отёк с дегрануляцией тучных клеток', E'3'),
  (E'654495bb-e350-450f-93f0-1953d50ac24c', E'f182b2bb-a787-409b-b7e6-4b41f91d1809', E'Степень нарушения функции зависит не только от количества амилоида, но и от органа и распределения депозитов', E'0'),
  (E'fb1960d9-6065-4f91-9790-bdf97902daad', E'f182b2bb-a787-409b-b7e6-4b41f91d1809', E'Амилоидные отложения всегда ограничиваются сосудами и не поражают паренхиму', E'1'),
  (E'51307640-b091-4833-ba74-1278363a8319', E'f182b2bb-a787-409b-b7e6-4b41f91d1809', E'При одинаковой массе депозитов все органы поражаются одинаково', E'2'),
  (E'60256fbd-1bfc-41c8-b9ad-d741a4d5c6c5', E'c1c089aa-0e96-436b-89c0-d7a63dc73cad', E'Эозинофилы и тучные клетки могут участвовать в реакции; медиаторы вызывают отёк, вазодилатацию и бронхоспазм', E'0'),
  (E'8f82a6b2-5a19-4c53-9bd1-7812c16cebca', E'c1c089aa-0e96-436b-89c0-d7a63dc73cad', E'Линейное отложение IgG вдоль базальной мембраны и полулуния в клубочках', E'1'),
  (E'b15f62e8-7ddc-4493-a7a1-e846d439bd0f', E'c1c089aa-0e96-436b-89c0-d7a63dc73cad', E'Гранулярные иммунные комплексы с фибриноидным некрозом сосудов как обязательная картина', E'2'),
  (E'70973f3a-2c8b-4222-8686-dd0cbc47d660', E'c1c089aa-0e96-436b-89c0-d7a63dc73cad', E'Казеозный некроз с эпителиоидными клетками и гигантскими клетками', E'3'),
  (E'7a972dd1-b613-4fd7-8b2f-075e3f9d163c', E'4c72a3b9-9728-4f57-b806-5c14e2da9c65', E'Опираться только на частоту простуд, не исследуя иммунные показатели', E'0'),
  (E'8a850071-4e02-4d9c-9ec6-2f9381f3eb40', E'4c72a3b9-9728-4f57-b806-5c14e2da9c65', E'Сопоставлять клинический спектр инфекций с количественной и функциональной оценкой иммунных звеньев и возможными вторичными причинами', E'1'),
  (E'556d91af-28e5-455d-8e64-94960a1f91e8', E'4c72a3b9-9728-4f57-b806-5c14e2da9c65', E'Считать любую аутоантителопозитивность доказательством комбинированного иммунодефицита', E'2'),
  (E'ba20a150-1324-4314-aa13-b2a28c9752e6', E'4c72a3b9-9728-4f57-b806-5c14e2da9c65', E'Диагностировать первичный иммунодефицит только по увеличению лимфоузлов', E'3'),
  (E'24d8024d-c054-4f80-a19c-53d680e4b791', E'514d2ef7-f521-4743-9165-8d6838ac4cf5', E'Клональные плазматические клетки продуцируют лёгкие цепи, из которых формируются амилоидные фибриллы, нарушающие структуру и функцию почек', E'0'),
  (E'5aa3413e-713a-4524-81bd-fb86f19cea97', E'514d2ef7-f521-4743-9165-8d6838ac4cf5', E'Плазматические клетки превращаются в эпителий почечных канальцев', E'1'),
  (E'74ce6a73-e82b-43ce-a5a4-5fce79f63aa2', E'514d2ef7-f521-4743-9165-8d6838ac4cf5', E'IgE связывает клубочковые рецепторы и превращается в конгофильный материал', E'2'),
  (E'6ddc7943-f695-4b6c-a9ea-70dd4c06ebb0', E'514d2ef7-f521-4743-9165-8d6838ac4cf5', E'Лёгкие цепи всегда вызывают только острый бактериальный пиелонефрит', E'3'),
  (E'9dc97a06-22b4-404f-9f41-92879b3d1ccc', E'4722c087-b209-459e-b109-b9b2fd8459f7', E'Иммунные комплексы задерживаются в фильтрующих и гемодинамически уязвимых структурах, активируют комплемент и привлекают воспалительные клетки', E'0'),
  (E'bd91b964-4183-45f4-b2a4-a28a59700a69', E'4722c087-b209-459e-b109-b9b2fd8459f7', E'Антитела всегда стимулируют эндотелиальные рецепторы без воспаления', E'1'),
  (E'c57d8471-588a-498f-9d80-9bc6ce509429', E'4722c087-b209-459e-b109-b9b2fd8459f7', E'Тучные клетки избирательно разрушают все базальные мембраны', E'2'),
  (E'798c7be6-70ca-4474-8c9c-9be7f3611d67', E'4722c087-b209-459e-b109-b9b2fd8459f7', E'T-лимфоциты превращаются в амилоидные фибриллы в просвете капилляров', E'3');
INSERT INTO public.question_options (id, question_id, option_text, sort_order) VALUES
  (E'44b4cc0e-8e56-4c3d-8809-37052885c367', E'23f183a7-915c-41ef-8bdc-5abae949f3d7', E'Любое обнаруженное аутоантитело обязательно непосредственно разрушает ткань', E'0'),
  (E'5d20dbf3-e319-4144-a6a2-3fc04cff315f', E'23f183a7-915c-41ef-8bdc-5abae949f3d7', E'Некоторые аутоантитела отражают потерю толерантности, но степень их патогенности зависит от мишени, класса и механизма действия', E'1'),
  (E'4f350647-549f-4258-a24d-b80bda1a9870', E'23f183a7-915c-41ef-8bdc-5abae949f3d7', E'Аутоантитела не имеют диагностического значения', E'2'),
  (E'022d09b6-8039-4685-a7c9-cd17977f7f8c', E'23f183a7-915c-41ef-8bdc-5abae949f3d7', E'Патогенными бывают только IgE-аутоантитела', E'3'),
  (E'35d6867b-7fb8-4d30-9a47-b39cca8ce463', E'9a29bd7c-180d-4661-9224-4f3a788ffc07', E'Вариант ответа 4', E'3'),
  (E'418356f3-327b-43d1-b146-ec0fd18a929e', E'e7727bde-ab71-474f-8a77-51f81ab987aa', E'На внутриклеточные и внеклеточные в зависимости от места накопления', E'0'),
  (E'd21269db-08a1-46d2-b7c4-977cfd0943c8', E'e7727bde-ab71-474f-8a77-51f81ab987aa', E'На железосодержащие и безжелезистые в зависимости от химического состава', E'1'),
  (E'98b1cade-5a89-43b4-bf78-2113cd2ba0fa', E'e7727bde-ab71-474f-8a77-51f81ab987aa', E'На экзогенные и эндогенные в зависимости от происхождения', E'2'),
  (E'951ab2ec-e0ad-4e25-8551-ce9cb6456eab', E'e7727bde-ab71-474f-8a77-51f81ab987aa', E'На растворимые и нерастворимые в зависимости от физико-химических свойств', E'3'),
  (E'e00d0c1d-28b3-44c9-b3ad-92d150017645', E'97fa6af8-ae26-43d0-a5c9-e4f669462c1b', E'Распространённое накопление железа в печени, поджелудочной железе и других органах', E'0'),
  (E'cab76013-d8a2-4006-a1c7-34de72e10dcf', E'97fa6af8-ae26-43d0-a5c9-e4f669462c1b', E'Локальное накопление билирубина в гепатоцитах при нарушении оттока желчи', E'1'),
  (E'94a7d420-0972-4207-b280-c0d8f33bc260', E'97fa6af8-ae26-43d0-a5c9-e4f669462c1b', E'Отложение гемосидерина в ограниченном участке после кровоизлияния или локального венозного застоя', E'2'),
  (E'344225f6-365b-4e28-ad9a-166682fc3e00', E'97fa6af8-ae26-43d0-a5c9-e4f669462c1b', E'Диффузное отложение кальциевых солей в неповреждённых тканях', E'3'),
  (E'91125f7d-6f25-40a2-ad9e-384e9e3b0ca4', E'b2e8dd1e-51d9-456d-9c59-28d9866be347', E'Увеличение содержания гемосидерина в тканях при усиленном распаде эритроцитов', E'0'),
  (E'd708fe45-6798-4bde-9b31-39c799ecb36f', E'b2e8dd1e-51d9-456d-9c59-28d9866be347', E'Накопление липофусцина в долгоживущих клетках при старении или окислительном стрессе', E'1'),
  (E'd1dab216-4b6f-4d36-a4c4-bb7a466d9a87', E'b2e8dd1e-51d9-456d-9c59-28d9866be347', E'Накопление билирубина в крови и тканях при нарушении его образования, переработки или выведения', E'2'),
  (E'25e93f03-50d9-4a4b-a2a8-2270b2d077f1', E'b2e8dd1e-51d9-456d-9c59-28d9866be347', E'Отложение гематоидина в старых очагах кровоизлияния', E'3'),
  (E'14afe927-3dd1-4e07-94e3-6fc40fab08b6', E'428c59c9-5042-411d-80b7-52711b941354', E'Преимущественное накопление неконъюгированного билирубина в крови при усиленном гемолизе', E'0'),
  (E'6cfcb876-f733-4356-9316-e1f10591e203', E'428c59c9-5042-411d-80b7-52711b941354', E'Желчные тромбы и пигмент в гепатоцитах или желчных канальцах при задержке желчи', E'1'),
  (E'2425b63e-148a-4e63-aed6-0da2f4dcb5bf', E'428c59c9-5042-411d-80b7-52711b941354', E'Снижение содержания желчных пигментов в канальцах при усиленном оттоке желчи', E'2'),
  (E'1329f8de-57b3-4511-b5a4-ea0d7a2c644f', E'428c59c9-5042-411d-80b7-52711b941354', E'Накопление железосодержащего пигмента в макрофагах после распада эритроцитов', E'3'),
  (E'e049f412-bdee-4725-b3ba-15e4a249e40a', E'a36d93df-df50-4bca-b579-db9505b602bb', E'Связывание и выведение железа из клеток с желчью', E'0'),
  (E'323c8980-15d7-47b5-992f-4015bdc83eb2', E'a36d93df-df50-4bca-b579-db9505b602bb', E'Формирование желтушного окрашивания при повышении концентрации в крови', E'1'),
  (E'2c67bafd-27ba-4f00-9f2a-834a7665cb89', E'a36d93df-df50-4bca-b579-db9505b602bb', E'Поглощение части ультрафиолетового излучения и формирование окраски кожи, волос и радужки', E'2'),
  (E'b23d753f-515d-424b-9192-f962ada0d9b2', E'a36d93df-df50-4bca-b579-db9505b602bb', E'Образование остаточных лизосомальных гранул при старении клеток', E'3'),
  (E'8ca0a40e-606f-493b-86dd-f6711d064f1d', E'5c0fa65c-7367-4f7b-a6e0-3291f5582883', E'Увеличение органа с желтоватой окраской из-за накопления билирубина', E'0'),
  (E'b5a201fc-9d6e-4b9e-908f-835bc7944077', E'5c0fa65c-7367-4f7b-a6e0-3291f5582883', E'Уменьшение органа с буроватой окраской из-за накопления липофусцина в клетках', E'1'),
  (E'427d7f97-c8e2-4be8-be64-f1fbd3d726c1', E'5c0fa65c-7367-4f7b-a6e0-3291f5582883', E'Уменьшение органа с ржаво-бурой окраской из-за диффузного отложения гемосидерина', E'2'),
  (E'6a0b303a-7499-417d-9789-a67e2cc0645f', E'5c0fa65c-7367-4f7b-a6e0-3291f5582883', E'Увеличение органа с тёмной окраской из-за накопления угольных частиц', E'3'),
  (E'2e256ef2-1f1e-4596-a079-75db75c07e17', E'78e3e3cd-659f-4284-8f06-d0e20e211515', E'В старых очагах коагуляционного некроза при локальном повреждении ткани', E'0'),
  (E'1c9f71c0-d01c-420d-ab55-6a1d33fab02b', E'78e3e3cd-659f-4284-8f06-d0e20e211515', E'В почках, лёгких, слизистой оболочке желудка и стенках сосудов при системных нарушениях обмена кальция', E'1'),
  (E'ac5d59d5-e172-4308-a17a-cce41b98978d', E'78e3e3cd-659f-4284-8f06-d0e20e211515', E'Преимущественно в макрофагах печени при усиленном распаде эритроцитов', E'2'),
  (E'ef08ad69-df9d-4625-8a0d-7b9b4b8d79b7', E'78e3e3cd-659f-4284-8f06-d0e20e211515', E'В коже и радужке при усилении синтеза пигмента меланоцитами', E'3'),
  (E'eb390225-6da0-4ae5-b907-31a4614cd620', E'ede649d1-b77c-4ab4-a316-a51f95814b42', E'Кариорексис, кариопикноз, затем восстановление структуры ядра', E'0'),
  (E'c5c790b2-038d-454b-bab3-987ec7198e66', E'ede649d1-b77c-4ab4-a316-a51f95814b42', E'Кариолизис, митоз и последующая фрагментация ядра', E'1'),
  (E'71b57c4c-e01a-425e-b306-ca71c59574ea', E'ede649d1-b77c-4ab4-a316-a51f95814b42', E'Кариопикноз, затем кариорексис и кариолизис как типичные ядерные изменения при некрозе', E'2'),
  (E'79c277cd-85c9-4d95-8e47-b8cc7e53ffa6', E'ede649d1-b77c-4ab4-a316-a51f95814b42', E'Метаплазия, гиперплазия и кариопикноз как последовательные стадии', E'3'),
  (E'ab8e17d7-ae0e-4ff4-881e-1f5f79e17639', E'55439946-1264-4de1-b551-af9fde586c6d', E'Коагуляционный некроз с сохранением контуров ткани, типичный для большинства инфарктов плотных органов', E'0'),
  (E'bcf6e93c-9149-4b43-a24e-a8528cf1b2f7', E'55439946-1264-4de1-b551-af9fde586c6d', E'Колликвационный некроз с жидким содержимым вследствие ферментативного переваривания', E'1'),
  (E'36487213-6830-487b-9550-c51b1a660c34', E'55439946-1264-4de1-b551-af9fde586c6d', E'Казеозный некроз с утратой нормальной тканевой архитектуры и творожистыми массами в центре очага', E'2'),
  (E'4fc34c16-116f-4d8b-b967-1ee20cd84f56', E'3d236918-02f7-4710-9881-081054479b59', E'Накопление угольных частиц преимущественно в макрофагах лёгких с возможным переносом в лимфатические узлы', E'0'),
  (E'0584dac1-c76b-482a-8713-d05f38da5a6c', E'3d236918-02f7-4710-9881-081054479b59', E'Накопление железосодержащего пигмента в макрофагах лёгких после повторных кровоизлияний', E'1'),
  (E'2c00ad4a-d0f9-4152-8b99-d841464f937d', E'3d236918-02f7-4710-9881-081054479b59', E'Отложение меланина в альвеолярных макрофагах с распространением по лимфатическим путям', E'2'),
  (E'0c7fbdb5-b9c8-46b0-ac92-1f0c5968b45e', E'3d236918-02f7-4710-9881-081054479b59', E'Отложение кальциевых солей в лёгочной ткани после хронического воспаления', E'3'),
  (E'2ba4be3c-d948-466c-8dd1-ec8c45c7eb22', E'85a9eb50-6f14-4bb1-b6ca-8e1ff0eb1db8', E'Однократное небольшое кровоизлияние с распадом эритроцитов в ограниченном участке ткани', E'0'),
  (E'e84f73ce-0282-4fc1-95ba-834b7091c8c9', E'85a9eb50-6f14-4bb1-b6ca-8e1ff0eb1db8', E'Повторный внутрисосудистый гемолиз или многократные переливания крови с перегрузкой железом', E'1'),
  (E'1156a6e1-1879-4f8a-8b6c-b536267c9b49', E'85a9eb50-6f14-4bb1-b6ca-8e1ff0eb1db8', E'Хроническая обструкция желчных путей с накоплением конъюгированного билирубина', E'2'),
  (E'2c66169d-aa13-4cc6-8a64-de41f2b7638c', E'85a9eb50-6f14-4bb1-b6ca-8e1ff0eb1db8', E'Усиленный синтез меланина при активации меланоцитов кожи', E'3'),
  (E'dd2d465c-74db-4982-81b6-0460676bfd3e', E'c8647970-dcd2-474a-88cd-ef3e2a6f2d0a', E'Уменьшение захвата неконъюгированного билирубина гепатоцитами при сохранном распаде эритроцитов', E'0'),
  (E'fdf85d5d-bc5f-4a12-a7c9-e923c685375c', E'c8647970-dcd2-474a-88cd-ef3e2a6f2d0a', E'Усиленное образование билирубина при распаде эритроцитов, превышающее возможности его переработки печенью', E'1'),
  (E'1fe64b3b-c21a-4f26-80fe-78eec2103c6e', E'c8647970-dcd2-474a-88cd-ef3e2a6f2d0a', E'Нарушение конъюгации билирубина гепатоцитами при первичном повреждении печени', E'2'),
  (E'a0a11c31-289a-45e5-9f52-e62fd6988539', E'c8647970-dcd2-474a-88cd-ef3e2a6f2d0a', E'Препятствие оттоку желчи с обратным поступлением конъюгированного билирубина в кровь', E'3'),
  (E'b0f79324-90ba-4e79-b101-7eeb20184747', E'4cd88440-5f10-4f92-86bf-3b175dfa697b', E'В гепатоцитах при нарушении конъюгации билирубина', E'0'),
  (E'cb3003d2-0ab9-407e-9f45-b8a0cf60b822', E'4cd88440-5f10-4f92-86bf-3b175dfa697b', E'В макрофагах лёгких после фагоцитоза угольных частиц', E'1'),
  (E'5265cf9a-1e9a-4490-8d14-3d60b7a97a44', E'4cd88440-5f10-4f92-86bf-3b175dfa697b', E'В старых очагах кровоизлияния как железосодержащий продукт распада гемоглобина', E'2'),
  (E'92b53917-222b-4a24-85a7-6318275dfd10', E'4cd88440-5f10-4f92-86bf-3b175dfa697b', E'В старых очагах кровоизлияния как железонесодержащий продукт распада гемоглобина', E'3'),
  (E'56f5cd4a-aea5-48c1-b2b8-90742e4ba32a', E'5951240e-9b01-4cb4-8d4f-421360a0a461', E'Избыточное или необычное накопление меланина в тканях', E'0'),
  (E'1dd7800e-71b7-4ed9-bb87-65677f1278f2', E'5951240e-9b01-4cb4-8d4f-421360a0a461', E'Накопление билирубина в тканях при нарушении желчеоттока', E'1'),
  (E'e6e5b162-9afa-415d-a307-c352567e68d2', E'5951240e-9b01-4cb4-8d4f-421360a0a461', E'Отложение гемосидерина в тканях при перегрузке железом', E'2'),
  (E'97d378e6-4759-44ab-852a-5233a0018697', E'5951240e-9b01-4cb4-8d4f-421360a0a461', E'Накопление липофусцина в долгоживущих клетках при старении', E'3'),
  (E'ee6854b7-3850-49ed-a7b2-2f4acdbe9acf', E'e48b761e-66d5-4cce-92b1-47e4194b3c56', E'Отложение кальциевых солей в повреждённой или некротической ткани при обычно нормальном уровне кальция крови', E'0'),
  (E'93e0d2d2-975e-470a-a48f-04be141943d1', E'e48b761e-66d5-4cce-92b1-47e4194b3c56', E'Отложение кальциевых солей в относительно сохранных тканях на фоне системной гиперкальциемии', E'1'),
  (E'5e2305fc-f1a5-46fe-b867-fc241e37c3f8', E'e48b761e-66d5-4cce-92b1-47e4194b3c56', E'Отложение солей железа в тканях после распада эритроцитов', E'2'),
  (E'59807c69-8add-4766-b1af-6f7600c7cf17', E'e48b761e-66d5-4cce-92b1-47e4194b3c56', E'Отложение уратов в тканях при нарушении обмена мочевой кислоты', E'3'),
  (E'94fa146b-f174-452a-93d4-10a6cdc7c15e', E'61ebf849-8e92-4aa6-985b-abcfc8f6856b', E'Реакцией Перлса, выявляющей трёхвалентное железо с образованием синего окрашивания', E'0'),
  (E'e44bd250-f61b-4492-a443-164592691f29', E'61ebf849-8e92-4aa6-985b-abcfc8f6856b', E'ШИК-реакцией, выявляющей углеводные компоненты в цитоплазме', E'1'),
  (E'9aad8843-7674-49ce-98ee-74fabf5f064c', E'61ebf849-8e92-4aa6-985b-abcfc8f6856b', E'Окраской судановыми красителями, выявляющей нейтральные жиры', E'2'),
  (E'8996663f-1aa9-4b78-8c67-1fb5b8cdcfc6', E'61ebf849-8e92-4aa6-985b-abcfc8f6856b', E'Окраской по Цилю—Нильсену, выявляющей кислотоустойчивые микроорганизмы', E'3'),
  (E'6c3e6743-cc32-4d7f-896c-c2f6fe121497', E'42d6d416-fc55-40ed-8ac2-b23f9dd5da84', E'Быстрое ферментативное разжижение ткани с исчезновением её контуров', E'0'),
  (E'2fecf549-36ba-4551-ae8e-21593f52190e', E'42d6d416-fc55-40ed-8ac2-b23f9dd5da84', E'Сохранение общих контуров ткани некоторое время при денатурации белков и утрате ядер', E'1'),
  (E'362ce5e3-8b15-4eb7-8604-fdb739559493', E'42d6d416-fc55-40ed-8ac2-b23f9dd5da84', E'Формирование творожистых масс с полной утратой тканевой архитектуры', E'2'),
  (E'359bd33d-9f27-42bc-a072-75826704e0c1', E'42d6d416-fc55-40ed-8ac2-b23f9dd5da84', E'Преимущественное отложение фибрина в стенках сосудов при иммунном повреждении', E'3'),
  (E'ebf113f3-a1ae-4848-8c45-e965c28222a5', E'a0c38049-e60e-4f49-ac94-ffbc1b6cfef2', E'Очаг обратимого повреждения ткани с сохранением жизнеспособных клеток', E'0'),
  (E'44b340ad-70a4-45e4-9a2f-4d4986597117', E'a0c38049-e60e-4f49-ac94-ffbc1b6cfef2', E'Некроз тканей, часто сообщающихся с внешней средой, с изменением цвета и возможным присоединением инфекции', E'1'),
  (E'6f9ffc86-b977-48dc-aa06-13d15ad95cf2', E'a0c38049-e60e-4f49-ac94-ffbc1b6cfef2', E'Любой инфаркт плотного органа независимо от локализации и состояния ткани', E'2'),
  (E'197875de-4084-48a7-aaca-a2e5f734b9ed', E'a0c38049-e60e-4f49-ac94-ffbc1b6cfef2', E'Изолированное отложение пигмента в ткани без гибели клеток', E'3'),
  (E'cb638283-09df-42b3-9d9c-ad0874872878', E'bdf767c9-35a0-47b8-9883-7b9373838b42', E'Очаг кровоизлияния с накоплением гемосидерина после повреждения сосудов', E'0'),
  (E'b777991f-e87c-407b-9ce1-6fdf7fcf3477', E'bdf767c9-35a0-47b8-9883-7b9373838b42', E'Очаг ишемического некроза вследствие резкого прекращения или критического снижения кровоснабжения ткани', E'1'),
  (E'c34afdca-4b4b-42a2-8373-3a72e59841f8', E'f92de2c3-5c00-43f7-8d9f-bbc704bd44f0', E'Железосодержащий пигмент, возникающий при переработке гемоглобина макрофагами', E'1'),
  (E'5f131961-6a08-4d33-966a-d1d396a90a62', E'f92de2c3-5c00-43f7-8d9f-bbc704bd44f0', E'Остаточный пигмент лизосом, образующийся при окислении липидов и белков', E'2'),
  (E'cec89438-d355-4e55-979e-8b6dc4e4cdf6', E'f92de2c3-5c00-43f7-8d9f-bbc704bd44f0', E'Пигмент меланоцитов, синтезируемый из тирозина', E'3'),
  (E'fccc68b7-0035-4040-92cd-aefb9cc33b17', E'99dfcfce-a85b-422f-8c29-10b1b9271838', E'Накопление железа в органах вследствие нарушения его обмена, иногда с повреждением клеток и фиброзом', E'0'),
  (E'11286a11-c437-4cbd-abf9-bacd7393da0e', E'99dfcfce-a85b-422f-8c29-10b1b9271838', E'Накопление билирубина в тканях вследствие нарушения его конъюгации и выведения', E'1'),
  (E'76657357-ecc3-4669-b6d9-cdceac6bdb2f', E'99dfcfce-a85b-422f-8c29-10b1b9271838', E'Отложение гемосидерина только в очагах старых кровоизлияний без системного нарушения обмена железа', E'2'),
  (E'89d661fd-1ee4-4ed2-aa9e-a60c94329ccb', E'99dfcfce-a85b-422f-8c29-10b1b9271838', E'Избыточное образование порфиринов с преимущественным поражением кожи и нервной системы', E'3'),
  (E'aa73813f-8769-49b1-94f1-c5a842432a4e', E'7523272a-7cd4-475e-a041-43d740506570', E'Преимущественное повышение неконъюгированного билирубина вследствие ускоренного распада эритроцитов', E'0'),
  (E'04c231ae-9f9c-4a28-bf37-44e659ffc5d8', E'7523272a-7cd4-475e-a041-43d740506570', E'Нарушение захвата и конъюгации билирубина при повреждении гепатоцитов', E'1'),
  (E'c8f77232-3318-4ef7-87a4-1851f61255c3', E'7523272a-7cd4-475e-a041-43d740506570', E'Препятствие оттоку желчи с задержкой преимущественно конъюгированного билирубина', E'2'),
  (E'7bcc1fb3-ed26-4223-9c62-b17dc1124cec', E'7523272a-7cd4-475e-a041-43d740506570', E'Изолированное усиление образования билирубина при сохранном оттоке желчи', E'3'),
  (E'2406c02e-66c0-4687-b370-ca5e05b74afb', E'8f701fe4-379c-4a6d-ab1a-fc3e26cec5ed', E'Конечные продукты распада гемоглобина, которые запасают железо в макрофагах', E'0'),
  (E'c4ffc6a5-e869-4b23-83ee-4f8943ef4dd6', E'8f701fe4-379c-4a6d-ab1a-fc3e26cec5ed', E'Промежуточные соединения пути синтеза гема, способные накапливаться при порфириях', E'1'),
  (E'b19bb75b-809e-4856-9eaa-7919cf9d65e1', E'8f701fe4-379c-4a6d-ab1a-fc3e26cec5ed', E'Продукты конъюгации билирубина, выводимые с желчью', E'2'),
  (E'd9962406-6fc2-48e0-b977-ab3ff9f92398', E'8f701fe4-379c-4a6d-ab1a-fc3e26cec5ed', E'Пигменты, образующиеся при окислении липидов в лизосомах', E'3'),
  (E'bc72b5dd-f810-46a6-bab5-02748f30d11e', E'a929c932-f44c-4b31-b305-8096b945bd18', E'Накопление железосодержащих гранул после распада гемоглобина', E'0'),
  (E'bdef6d6e-ae08-4ba5-9f60-354f5baa82c3', E'a929c932-f44c-4b31-b305-8096b945bd18', E'Накопление остаточных продуктов окисления липидов и белков в лизосомах, особенно при старении клеток', E'1'),
  (E'6c528028-0f39-4924-a5ae-f64b7f4566cf', E'a929c932-f44c-4b31-b305-8096b945bd18', E'Накопление конъюгированного билирубина при нарушении оттока желчи', E'2'),
  (E'fdd34745-d9e1-4edc-a6cd-de17f6934b34', E'a929c932-f44c-4b31-b305-8096b945bd18', E'Отложение меланина вследствие усиления синтеза в меланоцитах', E'3'),
  (E'5e198255-e34a-4954-bb79-85a488e26158', E'89fcb18a-8ab7-4f91-bd26-df10c0079def', E'Локальное повреждение ткани с некрозом при нормальном уровне кальция крови', E'0'),
  (E'd28496e1-a2b4-47bc-80ee-28095840e2ec', E'89fcb18a-8ab7-4f91-bd26-df10c0079def', E'Снижение уровня кальция крови при длительном дефиците витамина D', E'1'),
  (E'7975d035-259b-414e-ac26-335103c73124', E'89fcb18a-8ab7-4f91-bd26-df10c0079def', E'Системная гиперкальциемия или нарушение обмена кальция и фосфатов, создающие условия для отложения солей в тканях', E'2');
INSERT INTO public.question_options (id, question_id, option_text, sort_order) VALUES
  (E'56be9688-853d-464c-9db9-8b29259b42cf', E'89fcb18a-8ab7-4f91-bd26-df10c0079def', E'Изолированное повышение билирубина при нарушении оттока желчи', E'3'),
  (E'0320e74c-df94-44e3-842f-4cb2602e7935', E'98b726d8-eb02-4c3f-9f6d-38fed3446f64', E'Обратимое повреждение клеток с сохранением их жизнеспособности', E'0'),
  (E'9d6cd9d7-bde3-48cc-996b-0eb439f38a51', E'98b726d8-eb02-4c3f-9f6d-38fed3446f64', E'Прижизненная гибель клеток или участка ткани с необратимыми структурными изменениями', E'1'),
  (E'c610a681-c6b7-4237-b675-1f0ce94d74ed', E'98b726d8-eb02-4c3f-9f6d-38fed3446f64', E'Запрограммированная гибель отдельных клеток с характерными регулируемыми механизмами', E'2'),
  (E'6557381d-5024-4cfa-9768-f252f2fb7c4b', E'98b726d8-eb02-4c3f-9f6d-38fed3446f64', E'Увеличение числа клеток вследствие усиления их пролиферации', E'3'),
  (E'3877a13c-3267-4a18-b370-317be1492530', E'13c5d885-6f2b-4345-88fe-ca305acee4a3', E'Коагуляционного, при котором денатурация белков временно сохраняет контуры ткани', E'0'),
  (E'a4636564-07b5-4700-8b7e-ef40ec44aa47', E'13c5d885-6f2b-4345-88fe-ca305acee4a3', E'Казеозного, при котором формируются сухие крошковатые массы', E'1'),
  (E'9e1c4404-68cb-4087-9663-fbaf8cf1dd9d', E'13c5d885-6f2b-4345-88fe-ca305acee4a3', E'Колликвационного, при котором ферментативное переваривание приводит к размягчению и разжижению ткани', E'2'),
  (E'9d2d14a8-00de-4c30-be92-20b77c9c3e94', E'13c5d885-6f2b-4345-88fe-ca305acee4a3', E'Фибриноидного, при котором повреждается соединительная ткань и стенки сосудов', E'3'),
  (E'1576083c-8957-4f3c-9831-05903ed000ca', E'10bc2af8-fd6f-4fc4-93db-08ebb48180e6', E'Отёчная, размягчённая ткань с нечёткой границей и выраженным бактериальным распадом', E'0'),
  (E'33ca86be-704f-4082-bbe5-26312d090e7d', E'10bc2af8-fd6f-4fc4-93db-08ebb48180e6', E'Плотная, сухая, тёмная, мумифицированная ткань с относительно чёткой границей', E'1'),
  (E'1c4f4615-ffca-4bdd-a8c1-8906ee793764', E'10bc2af8-fd6f-4fc4-93db-08ebb48180e6', E'Рыхлая ткань с ферментативным разжижением и образованием полости', E'2'),
  (E'ba2f8d30-f986-4e01-b9d2-9dba2e17fb44', E'10bc2af8-fd6f-4fc4-93db-08ebb48180e6', E'Творожистая масса в центре гранулематозного воспаления', E'3'),
  (E'eaa116b5-a5d0-414a-bf8e-a0e49af4da8d', E'9dff5a62-a165-4120-846b-51a3b4b86dce', E'Красный инфаркт с геморрагическим пропитыванием ткани при двойном кровоснабжении', E'0'),
  (E'297ed846-03f8-4c65-9a8d-5f67d0712f77', E'9dff5a62-a165-4120-846b-51a3b4b86dce', E'Белый (ишемический) инфаркт, обычно клиновидный и обусловленный окклюзией конечной артериальной ветви', E'1'),
  (E'2cfa3c8e-daa3-4bb3-955c-a71b052e80ff', E'9dff5a62-a165-4120-846b-51a3b4b86dce', E'Колликвационный инфаркт с обязательным формированием полости в первые часы', E'2'),
  (E'803484d9-2439-427a-9670-4cf5d7ad2cd3', E'55439946-1264-4de1-b551-af9fde586c6d', E'Жировой некроз с омылением жиров и образованием меловидных участков', E'3'),
  (E'02afed46-809c-4277-8207-b8b7570cd1b2', E'796f46f7-f882-4ae6-b512-5b986e93dc2a', E'Постепенная потеря воды тканью при ограниченном ишемическом повреждении без инфекции', E'0'),
  (E'945ddd5d-f6d4-47de-8488-e199e3b70674', E'796f46f7-f882-4ae6-b512-5b986e93dc2a', E'Длительное накопление липофусцина в клетках с развитием бурой атрофии', E'1'),
  (E'dac6458b-ca65-4431-89ab-c1cb83dc4325', E'796f46f7-f882-4ae6-b512-5b986e93dc2a', E'Ишемия в сочетании с отёком и присоединением инфекции, ускоряющей распад тканей', E'2'),
  (E'81272802-fdf4-43b9-b64d-60dc1887cd0a', E'796f46f7-f882-4ae6-b512-5b986e93dc2a', E'Изолированное нарушение оттока желчи с накоплением желчных пигментов', E'3'),
  (E'1053f0ce-3b96-460c-b8a5-17df366104ff', E'04ad6836-507d-4d55-9933-a67c70771653', E'При окклюзии конечной артериальной ветви в плотном органе с ограниченным коллатеральным кровотоком', E'0'),
  (E'8db028e9-1748-4a0c-accb-77281050a2e0', E'04ad6836-507d-4d55-9933-a67c70771653', E'При венозной окклюзии, двойном кровоснабжении или в рыхлой ткани, где возможно пропитывание очага кровью', E'1'),
  (E'5833398a-cb1e-4576-a517-32c47f7036e9', E'04ad6836-507d-4d55-9933-a67c70771653', E'При локальном накоплении гемосидерина после старого кровоизлияния без ишемии', E'2'),
  (E'50dacbd0-cfe2-453a-bfc5-f4274e18554b', E'04ad6836-507d-4d55-9933-a67c70771653', E'При дистрофическом обызвествлении некротического участка без нарушения кровотока', E'3'),
  (E'5849873b-2c3b-4cfa-8080-4c5e7c8242d4', E'f4779588-681d-4830-b8ef-07c9de1b6acc', E'уменьшение объёма ткани вследствие снижения метаболической активности клеток', E'0'),
  (E'bf531de5-87e9-496e-802d-bb4f34b5a1ef', E'f4779588-681d-4830-b8ef-07c9de1b6acc', E'восстановление утраченных структур ткани или органа за счёт клеточных и внутриклеточных процессов', E'1'),
  (E'f0bb0446-c700-4835-9c03-d2f82d4660b1', E'f4779588-681d-4830-b8ef-07c9de1b6acc', E'замещение любого дефекта соединительной тканью независимо от сохранности паренхимы', E'2'),
  (E'698ea15b-4e76-4475-b833-c614d4399701', E'f4779588-681d-4830-b8ef-07c9de1b6acc', E'адаптивное увеличение массы органа в ответ на повышенную функциональную нагрузку', E'3'),
  (E'8c55b381-8667-4741-9c6d-1df085aa9701', E'1a508106-420a-434a-8683-5f8b7a625e87', E'сохранность базальной мембраны и источника регенерирующих клеток', E'0'),
  (E'19e5af6d-3340-4a55-b30c-d3ac40c8f091', E'1a508106-420a-434a-8683-5f8b7a625e87', E'полное разрушение стромального каркаса при сохранении воспаления', E'1'),
  (E'18b622af-4de7-4dd8-a569-ee2701fba2f1', E'1a508106-420a-434a-8683-5f8b7a625e87', E'формирование плотного коллагенового рубца до начала эпителизации', E'2'),
  (E'f8c67f08-5bab-4842-9212-b468db3edd53', E'1a508106-420a-434a-8683-5f8b7a625e87', E'длительная инфекция с повторным некрозом краёв дефекта', E'3'),
  (E'8d68cd0e-e173-46cd-b35c-852ed0ef761f', E'1b9eaa13-f44b-4a4a-bf57-a91baf136802', E'много новообразованных капилляров, фибробластов и клеток воспаления', E'0'),
  (E'25cad508-3905-461f-87ac-c6d811c15b5f', E'1b9eaa13-f44b-4a4a-bf57-a91baf136802', E'плотные упорядоченные пучки коллагена при минимальной клеточности', E'1'),
  (E'7d5b4298-16aa-42f2-a98a-fb033e86ddc6', E'1b9eaa13-f44b-4a4a-bf57-a91baf136802', E'отсутствие сосудов и практически полное отсутствие клеток', E'2'),
  (E'266f8e7c-4a1d-4018-afda-4e8a5abe18b1', E'1b9eaa13-f44b-4a4a-bf57-a91baf136802', E'зрелый коллагеновый матрикс без активного ремоделирования', E'3'),
  (E'bb8075b1-ccc8-475a-9912-b108f32240c0', E'4466e06d-b1db-47c5-9017-74843df0e75d', E'гипорегенерация — недостаточное или замедленное восстановление дефекта', E'0'),
  (E'd99c0a82-11b5-4fff-9e83-98e85a5ddace', E'4466e06d-b1db-47c5-9017-74843df0e75d', E'гиперрегенерация — избыточное образование ткани за пределами дефекта', E'1'),
  (E'52ebbcf3-ec4b-461f-91d7-7e0ca5ed3afc', E'4466e06d-b1db-47c5-9017-74843df0e75d', E'реституция — полное восстановление исходной тканевой архитектоники', E'2'),
  (E'03f29eec-5fc4-4181-b0da-743bb47c55ac', E'4466e06d-b1db-47c5-9017-74843df0e75d', E'метаплазия — замена одного зрелого типа ткани другим', E'3'),
  (E'c565cddc-f30f-4ae8-82a9-b07ed7a18ef5', E'27f32b95-9f86-4224-8f08-418a91ab027c', E'метапластический вариант патологической регенерации', E'0'),
  (E'952c82f9-9ed4-42f2-b151-86e5c98c4f62', E'27f32b95-9f86-4224-8f08-418a91ab027c', E'субституция с формированием коллагенового рубца', E'1'),
  (E'de098ee7-deb6-447e-943f-5da5eae138c8', E'27f32b95-9f86-4224-8f08-418a91ab027c', E'гиперплазия без изменения клеточной дифференцировки', E'2'),
  (E'a224bea3-bf08-4bba-ace6-e87b7742e978', E'27f32b95-9f86-4224-8f08-418a91ab027c', E'внутриклеточная регенерация органелл в прежних клетках', E'3'),
  (E'd39d99d4-05f1-400c-aef4-83b867abbfd7', E'89d6b4c9-5043-4767-bf6b-b6602bb07633', E'увеличение массы левого желудочка при хронической артериальной гипертензии', E'0'),
  (E'41cf787f-f966-45a7-a88e-fb0e0f1bc22d', E'89d6b4c9-5043-4767-bf6b-b6602bb07633', E'уменьшение почки при стенозе почечной артерии и хронической ишемии', E'1'),
  (E'8a7f5dc8-9863-49e2-a02a-bb7ebf408b55', E'89d6b4c9-5043-4767-bf6b-b6602bb07633', E'увеличение объёма мышцы за счёт жирового замещения атрофированных волокон', E'2'),
  (E'f861a363-5c35-4c34-a0d1-1dd540905362', E'89d6b4c9-5043-4767-bf6b-b6602bb07633', E'уменьшение эндокринной ткани при дефиците соответствующего гормона', E'3'),
  (E'9f51b5ee-241b-42b3-8d55-30c3101bd986', E'67be22ef-0f96-428b-8de0-a56cd8fba379', E'викарная гипертрофия парного органа', E'0'),
  (E'4da7499a-4451-4325-bd38-378ef19f1bea', E'67be22ef-0f96-428b-8de0-a56cd8fba379', E'рабочая гипертрофия органа при постоянном повышении давления', E'1'),
  (E'6d16c48b-9f00-4d7c-b56c-e65cc41ccbba', E'67be22ef-0f96-428b-8de0-a56cd8fba379', E'ложная гипертрофия вследствие жирового замещения паренхимы', E'2'),
  (E'b3b84b27-5697-4e02-b87b-2e0888ecad6a', E'67be22ef-0f96-428b-8de0-a56cd8fba379', E'компенсаторная атрофия вследствие снижения нагрузки', E'3'),
  (E'ab496f9d-4a02-4f5a-9230-3f5733912fd8', E'ecc68018-f8e3-4171-a1f5-54b319ce6977', E'денервационная атрофия вследствие утраты нервного и трофического влияния', E'0'),
  (E'57899b3b-fa0c-4dff-80b8-3b1bb5026430', E'ecc68018-f8e3-4171-a1f5-54b319ce6977', E'рабочая гипертрофия вследствие усиления синтеза миофибрилл', E'1'),
  (E'1486f940-95d8-447b-bc16-36214f782e72', E'ecc68018-f8e3-4171-a1f5-54b319ce6977', E'гиперплазия зрелых кардиомиоцитов с увеличением мышечной массы', E'2'),
  (E'be285999-a886-4d4b-bb40-47c671719a98', E'ecc68018-f8e3-4171-a1f5-54b319ce6977', E'ложная гипертрофия без уменьшения функциональных волокон', E'3'),
  (E'8d7625ec-3b28-4de3-a774-28f6f7275acc', E'bdf767c9-35a0-47b8-9883-7b9373838b42', E'Обратимое нарушение кровоснабжения с восстановлением структуры ткани', E'2'),
  (E'3303f1ee-6d80-4d34-b2b1-4a35f025055e', E'bdf767c9-35a0-47b8-9883-7b9373838b42', E'Очаг колликвационного некроза независимо от причины и кровоснабжения', E'3'),
  (E'6daa55e8-b8b8-41be-8462-875219368520', E'2e09fd82-2ce5-463d-9248-f57d9c16fa3b', E'Полное восстановление нормальной тканевой архитектуры после любого крупного инфаркта', E'0'),
  (E'2a1fa8e4-20ca-4fcf-a441-b010e96e6c19', E'2e09fd82-2ce5-463d-9248-f57d9c16fa3b', E'Организация с формированием рубца; в головном мозге после колликвации может образоваться киста', E'1'),
  (E'0994792f-daf9-42e3-87e1-e3a205844526', E'2e09fd82-2ce5-463d-9248-f57d9c16fa3b', E'Обязательное формирование гнойной полости независимо от причины инфаркта', E'2'),
  (E'ace9251d-c26e-467c-94b9-b1772360660b', E'2e09fd82-2ce5-463d-9248-f57d9c16fa3b', E'Диффузное отложение гемосидерина во всех органах как закономерный исход', E'3'),
  (E'9fef2204-2604-41db-8833-79f832e6ad60', E'be74b242-99f3-4f66-abe4-40358da0511f', E'физиологическая, репаративная, патологическая', E'0'),
  (E'cda59380-1150-4b16-b3d8-e43bb92ab8aa', E'be74b242-99f3-4f66-abe4-40358da0511f', E'полная, неполная, внутриклеточная', E'1'),
  (E'f9b491b5-9435-4309-91d2-1f150b7ba9f8', E'be74b242-99f3-4f66-abe4-40358da0511f', E'клеточная, внутриклеточная, смешанная', E'2'),
  (E'7108d2b0-6007-4891-a2b5-1926b6a10060', E'be74b242-99f3-4f66-abe4-40358da0511f', E'ишемическая, компрессионная, дисгормональная', E'3'),
  (E'c8a776db-7ac2-4d77-ad86-5abb38a2bc12', E'793314de-a33d-4d21-a043-c1e249721257', E'замещение дефекта соединительной тканью с формированием рубца', E'0'),
  (E'158c3657-c4d9-47fe-9fcf-570d7c483075', E'793314de-a33d-4d21-a043-c1e249721257', E'восстановление ткани того же типа с восстановлением её архитектоники', E'1'),
  (E'95805b71-ec69-40b0-8d23-e69a7199f4dd', E'793314de-a33d-4d21-a043-c1e249721257', E'закрытие поверхности грануляционной тканью без восстановления паренхимы', E'2'),
  (E'b697522b-4348-4059-8b9c-59313bc45084', E'793314de-a33d-4d21-a043-c1e249721257', E'увеличение объёма органа за счёт стромы при атрофии паренхимы', E'3'),
  (E'a8bc8279-6009-474f-9804-b536627961d4', E'b53ea179-72c8-4a18-8809-ac8c76d1bdc5', E'уменьшаются объём дефекта, некротические массы и потребность в грануляционной ткани', E'0'),
  (E'912953d1-3024-49b9-b550-0bc03e1e7b03', E'b53ea179-72c8-4a18-8809-ac8c76d1bdc5', E'воспалительная фаза полностью отсутствует и эпителизация не требуется', E'1'),
  (E'f95f91fc-99bb-474c-a857-71947efcd810', E'b53ea179-72c8-4a18-8809-ac8c76d1bdc5', E'сразу восстанавливается исходная архитектоника всех повреждённых слоёв', E'2'),
  (E'ca994022-ca02-4ef3-a3c8-92181fa09aa1', E'b53ea179-72c8-4a18-8809-ac8c76d1bdc5', E'обязательно формируется выраженное гнойное воспаление, ускоряющее очищение', E'3'),
  (E'e9ebb84c-4c1b-42e1-8719-6d28eb852f13', E'19f9c29d-e4f1-4d60-bcdd-af40256b9c70', E'делением базальных клеток с последующей дифференцировкой и миграцией потомков к поверхности', E'0'),
  (E'a1c724b1-5a5a-4c26-8dff-00f736ece26b', E'19f9c29d-e4f1-4d60-bcdd-af40256b9c70', E'митотическим делением зрелых корнеоцитов на поверхности кожи', E'1'),
  (E'bdba0b23-5a2b-441c-95c5-593aa4ba1fc0', E'19f9c29d-e4f1-4d60-bcdd-af40256b9c70', E'замещением эпидермиса фибробластами с формированием тонкого рубца', E'2'),
  (E'9edb9a3b-b10d-4195-85f8-aa09a16b528e', E'19f9c29d-e4f1-4d60-bcdd-af40256b9c70', E'непрерывным образованием ядер без цитоплазматического деления', E'3'),
  (E'95b26d62-9006-42ec-bf95-aa62ad6293ad', E'4d03a4e1-62b0-44fd-a3fe-25fb7b177a05', E'функционально направленная адаптивная реакция, поддерживающая работу при изменившихся условиях', E'0'),
  (E'6e447b97-4b67-4877-aa81-6e98796ff1a7', E'4d03a4e1-62b0-44fd-a3fe-25fb7b177a05', E'процесс, который шире адаптации и не зависит от функциональной потребности', E'1'),
  (E'36a4aa5b-e13b-48dc-bd0e-9d2486c46c25', E'4d03a4e1-62b0-44fd-a3fe-25fb7b177a05', E'структурное изменение, всегда завершающееся полным выздоровлением', E'2'),
  (E'52e83118-ff91-4043-938b-da7b0498126a', E'4d03a4e1-62b0-44fd-a3fe-25fb7b177a05', E'ответ, который поддерживает функцию исключительно без морфологических изменений', E'3'),
  (E'e5f9d603-8045-4b16-9072-eaabdbd633de', E'd43715e8-5716-4dfd-a196-a4c7876ec262', E'увеличение массы функциональной паренхимы за счёт увеличения размеров клеток', E'0'),
  (E'daf8a4f3-c544-4943-a8c5-1d287c6cbe1e', E'd43715e8-5716-4dfd-a196-a4c7876ec262', E'увеличение объёма преимущественно за счёт жировой и соединительной ткани', E'1'),
  (E'b9ffd5d3-cd12-46c5-aa68-2f43e2132d93', E'd43715e8-5716-4dfd-a196-a4c7876ec262', E'увеличение органа вследствие интерстициального отёка без роста клеточных структур', E'2'),
  (E'1c5276b5-0d62-4e8c-873b-64ed3f5c2976', E'd43715e8-5716-4dfd-a196-a4c7876ec262', E'увеличение стромы на фоне уменьшения функциональных волокон', E'3'),
  (E'1d49b958-9e27-452b-af87-1edb260166a0', E'539f5835-809c-485d-9ddb-6116fa03db6c', E'длительное снижение гормонального сигнала, необходимого для поддержания ткани', E'0'),
  (E'60671b85-cdac-4dca-a558-56048c63eef9', E'539f5835-809c-485d-9ddb-6116fa03db6c', E'хроническое уменьшение перфузии при стенозе питающей артерии', E'1'),
  (E'39fb6dc8-376e-46a4-b5a6-d3886d3b141f', E'539f5835-809c-485d-9ddb-6116fa03db6c', E'длительное механическое сдавление ткани извне', E'2'),
  (E'ea4bcda6-fa1d-4f15-bdcc-ebafe291e53c', E'539f5835-809c-485d-9ddb-6116fa03db6c', E'снижение функциональной нагрузки при иммобилизации', E'3'),
  (E'1990f684-c94a-40fe-af42-b93ebaa9e827', E'fc128093-69fb-4c93-b3ac-e67e9706a15f', E'длительное внешнее давление на ткань с возможным нарушением микроциркуляции', E'0'),
  (E'426b15c5-d48b-4340-90bc-ba29f2a22c7f', E'fc128093-69fb-4c93-b3ac-e67e9706a15f', E'снижение нагрузки на орган при отсутствии его использования', E'1'),
  (E'b10ce194-2cec-46ee-9d21-7fa87a26a6c1', E'fc128093-69fb-4c93-b3ac-e67e9706a15f', E'уменьшение гормональной стимуляции клеток-мишеней', E'2'),
  (E'f0b129ea-fb21-4ae6-b2bc-c955be00b7b6', E'fc128093-69fb-4c93-b3ac-e67e9706a15f', E'первичное уменьшение кровотока без механического воздействия', E'3'),
  (E'08cf2cc2-7ac6-494f-8563-22df0cfb5711', E'ea709fa7-9879-47f9-8f9c-976ca0f854cc', E'реституция эпителия с восстановлением покрова без грубого рубцевания', E'0'),
  (E'd824f3cc-bb8e-4f90-899a-9b2812b7e3b3', E'ea709fa7-9879-47f9-8f9c-976ca0f854cc', E'субституция с обязательным замещением дефекта плотным коллагеном', E'1'),
  (E'64f3e1c0-c692-4ecf-97a2-69b23dd661de', E'ea709fa7-9879-47f9-8f9c-976ca0f854cc', E'организация дефекта с формированием грануляционной ткани на поверхности', E'2'),
  (E'65ea7fde-d7fb-4d87-ab66-8a993541e398', E'9dff5a62-a165-4120-846b-51a3b4b86dce', E'Венозный инфаркт с обязательным массивным кровоизлиянием в любой ткани', E'3'),
  (E'9ca8aac1-b4d3-4555-8c6b-1cb9b9bc39b9', E'90069419-473a-4bae-8132-2980c359a66b', E'внутриклеточная регенерация с обновлением органелл без увеличения числа клеток', E'0');
INSERT INTO public.question_options (id, question_id, option_text, sort_order) VALUES
  (E'7bcca841-61a6-45c1-a73f-dca1100f0684', E'90069419-473a-4bae-8132-2980c359a66b', E'клеточная регенерация с восполнением клеточной популяции', E'1'),
  (E'0c2c4e5a-df32-4936-a65e-8ba09e613c68', E'90069419-473a-4bae-8132-2980c359a66b', E'субституция с замещением паренхимы коллагеновым матриксом', E'2'),
  (E'4bcb5a9f-ecd7-433f-b1f5-48f29e6d6ab4', E'90069419-473a-4bae-8132-2980c359a66b', E'метаплазия с изменением дифференцировки зрелых клеток', E'3'),
  (E'1c402d4b-8f78-409b-b64e-2d141731a6be', E'72976e34-b631-4c6e-b365-93a49ba190a5', E'воспаление и гемостаз → пролиферация и ангиогенез → созревание и перестройка матрикса', E'0'),
  (E'551a672f-e8d9-435b-acae-8c6a21c8f999', E'72976e34-b631-4c6e-b365-93a49ba190a5', E'ангиогенез и созревание матрикса → гемостаз → воспаление', E'1'),
  (E'd27d5b5e-26a8-4c48-a43e-2fb3c75ecac2', E'72976e34-b631-4c6e-b365-93a49ba190a5', E'некроз → склероз → гемостаз → обязательное нагноение', E'2'),
  (E'ddc4546c-80d1-4faf-9b70-20735cde2eff', E'72976e34-b631-4c6e-b365-93a49ba190a5', E'эпителизация → фиброз до воспаления → образование тромба', E'3'),
  (E'702e0fb2-1a6f-4461-accd-3967eb8bd346', E'ec77f65f-6b11-41cc-bdce-31a64df0dcdb', E'дефект заполняется грануляционной тканью, сокращается и замещается более крупным рубцом', E'0'),
  (E'c413bd97-acdc-4a95-884c-0d43546e5ff0', E'ec77f65f-6b11-41cc-bdce-31a64df0dcdb', E'края соединяются без выраженной пролиферации фибробластов и без рубца', E'1'),
  (E'c04c8283-d568-456d-867a-a1abb073a7f1', E'ec77f65f-6b11-41cc-bdce-31a64df0dcdb', E'эпителий восстанавливается до очищения дефекта от некротических масс', E'2'),
  (E'ce8b19f2-96ca-4088-b1ac-c643ffe3f47d', E'ec77f65f-6b11-41cc-bdce-31a64df0dcdb', E'воспаление отсутствует, а исходная архитектоника возникает немедленно', E'3'),
  (E'5c9c05ed-2beb-497f-b1d8-c4ff4c48cfea', E'390e94a5-04d6-491c-9544-9812d31e789a', E'избыточное разрастание грануляционной ткани или келоид за пределами исходного дефекта', E'0'),
  (E'76624f63-3200-4be3-b934-69fa59fc1a81', E'390e94a5-04d6-491c-9544-9812d31e789a', E'постепенное снижение сосудистости грануляционной ткани и уплотнение коллагена', E'1'),
  (E'3c1ed41e-7e69-4d02-8c2b-73137ba491ac', E'390e94a5-04d6-491c-9544-9812d31e789a', E'эпителизация поверхности при небольшом дефекте и сохранном каркасе', E'2'),
  (E'9217224d-9df9-4127-ab78-f73754e565b4', E'390e94a5-04d6-491c-9544-9812d31e789a', E'замещение некротизированной паренхимы ограниченным зрелым рубцом', E'3'),
  (E'd06d7b80-e682-4707-8509-2ee36c8deede', E'9cfb822a-ae46-4fad-9487-739d46a3640c', E'организация некроза с формированием рубца из-за ограниченной регенерации кардиомиоцитов', E'0'),
  (E'ce05bd26-eb11-42e4-8499-3166c5184e2b', E'9cfb822a-ae46-4fad-9487-739d46a3640c', E'полная реституция за счёт массового митоза зрелых кардиомиоцитов', E'1'),
  (E'c891aedb-749e-46ba-9005-65058d86b633', E'9cfb822a-ae46-4fad-9487-739d46a3640c', E'метаплазия миокарда с образованием зрелого хряща', E'2'),
  (E'b88d8a89-e7da-436a-85ff-94ea5376babc', E'9cfb822a-ae46-4fad-9487-739d46a3640c', E'гиперплазия кардиомиоцитов с восстановлением исходной мышечной архитектоники', E'3'),
  (E'd53d3ae4-39bf-4171-a235-721e3b8228df', E'839c2da0-09bd-49aa-8000-1fdb24de5e23', E'структурно-функциональная перестройка в ответ на изменившиеся условия или нагрузку', E'0'),
  (E'47c9a3ec-decf-4b12-9adc-138ceeb0f01b', E'839c2da0-09bd-49aa-8000-1fdb24de5e23', E'необратимая гибель клеток с обязательным замещением соединительной тканью', E'1'),
  (E'eb5aeec4-048f-4fad-b336-be6aab913d4f', E'839c2da0-09bd-49aa-8000-1fdb24de5e23', E'увеличение только числа клеток независимо от функциональной потребности', E'2'),
  (E'b84e33e7-513a-466e-a508-4cd739d2672a', E'839c2da0-09bd-49aa-8000-1fdb24de5e23', E'любое увеличение объёма органа вследствие отёка или накопления жира', E'3'),
  (E'b7875506-62e0-4ab2-9db8-c62d72efb2b3', E'c56e75e2-4bc3-440b-919d-9726e80a7cbe', E'декомпенсацию гипертрофированного миокарда с дистрофией и дилатацией', E'0'),
  (E'a98d6d9e-c2d4-4b23-9f56-9b94bbba9f21', E'c56e75e2-4bc3-440b-919d-9726e80a7cbe', E'стадию устойчивой компенсации без повреждения кардиомиоцитов', E'1'),
  (E'58a7c5f0-277d-4892-aaa9-40cd3938ce74', E'c56e75e2-4bc3-440b-919d-9726e80a7cbe', E'физиологическую гипертрофию с сохранением нормального соотношения нагрузки и кровоснабжения', E'2'),
  (E'0143a4e4-e27f-4bb0-a1ae-a9731b2a36f6', E'c56e75e2-4bc3-440b-919d-9726e80a7cbe', E'викарную гипертрофию вследствие удаления парного органа', E'3'),
  (E'8df1e92f-a1eb-454f-972f-69e37e11d238', E'7646afbc-1ac6-4d80-a14a-b3647ff976d7', E'уменьшение размеров клеток и органа; в длительно атрофированных клетках возможен липофусцин', E'0'),
  (E'6d4e008d-a3fe-4793-a488-d101610584f8', E'7646afbc-1ac6-4d80-a14a-b3647ff976d7', E'увеличение размеров клеток с накоплением сократительных белков', E'1'),
  (E'cec0afbb-1141-4fce-9388-355778619c03', E'7646afbc-1ac6-4d80-a14a-b3647ff976d7', E'обязательное образование гранулём и гигантских многоядерных клеток', E'2'),
  (E'688ed65b-6173-47f7-b286-ec8a1be02eb1', E'7646afbc-1ac6-4d80-a14a-b3647ff976d7', E'замещение паренхимы хрящом при сохранении прежнего объёма органа', E'3'),
  (E'56f53c03-8f35-46d1-b87c-3f767215f980', E'f22a4661-584a-4b2d-9a1e-2c456316a984', E'организация с замещением очага грануляционной и затем соединительной тканью', E'0'),
  (E'82daaf51-b25a-4a61-b46c-c43397f85dfa', E'f22a4661-584a-4b2d-9a1e-2c456316a984', E'реституция с восстановлением погибшей паренхимы клетками того же типа', E'1'),
  (E'1023f051-0622-4352-8cf6-6db4f6d37807', E'f22a4661-584a-4b2d-9a1e-2c456316a984', E'гипертрофия сохранившихся клеток без прорастания очага', E'2'),
  (E'f372abd5-cd60-4c9f-81da-db82d7569658', E'f22a4661-584a-4b2d-9a1e-2c456316a984', E'лизис некротических масс без клеточной реакции и без образования матрикса', E'3'),
  (E'47231f36-e8b7-46aa-a405-6bf8cfafff5e', E'408ca301-b7a8-4727-a78e-b45922956989', E'гиперплазия — увеличение числа клеток ткани', E'0'),
  (E'a9b37aae-d5d5-471a-92fc-b3fdb929bdb0', E'408ca301-b7a8-4727-a78e-b45922956989', E'гипертрофия — увеличение размеров отдельных клеток', E'1'),
  (E'72f8f3b3-1349-4df5-9285-d6afb8a7c820', E'408ca301-b7a8-4727-a78e-b45922956989', E'метаплазия — замещение одного зрелого клеточного типа другим', E'2'),
  (E'b9a9fe46-17b8-418d-a57f-7664e8d1fc14', E'408ca301-b7a8-4727-a78e-b45922956989', E'атрофия — уменьшение размеров и/или числа клеток', E'3'),
  (E'26067337-7b1f-429c-9367-3bd256951c61', E'f5c1c0f0-5743-42e2-98c3-2fde2c8d6496', E'ишемическая атрофия вследствие хронического снижения кровоснабжения', E'0'),
  (E'8b8ae80a-765a-4ebd-99f4-1a2357194623', E'f5c1c0f0-5743-42e2-98c3-2fde2c8d6496', E'компрессионная атрофия вследствие внешнего давления на паренхиму', E'1'),
  (E'e9402eb1-2392-433e-a48b-e3e43ef4abf5', E'f5c1c0f0-5743-42e2-98c3-2fde2c8d6496', E'дисфункциональная атрофия вследствие снижения механической нагрузки', E'2'),
  (E'6474a07c-8127-4856-85d0-e631ec4fa82c', E'f5c1c0f0-5743-42e2-98c3-2fde2c8d6496', E'дисгормональная атрофия вследствие недостатка гормональной стимуляции', E'3'),
  (E'c006f05e-d76f-4224-ac7f-2c6d6f0646fd', E'd0f34ea9-a8c8-4599-ab5d-d494568404b5', E'фибробласты синтезируют матрикс, а миофибробласты также способствуют сокращению раны', E'0'),
  (E'69a85377-99dd-410d-844b-0bd0395f37ef', E'd0f34ea9-a8c8-4599-ab5d-d494568404b5', E'эпителиоциты синтезируют основную массу глубокого коллагенового матрикса', E'1'),
  (E'3dbf234c-dcfe-4e4a-aace-9ca426771f92', E'd0f34ea9-a8c8-4599-ab5d-d494568404b5', E'нейтрофилы формируют зрелые коллагеновые пучки на этапе воспаления', E'2'),
  (E'da9e120f-5f7b-4cc9-b7c9-3c778b02344e', E'd0f34ea9-a8c8-4599-ab5d-d494568404b5', E'эритроциты синтезируют внеклеточный матрикс после остановки кровотечения', E'3'),
  (E'869e689b-ab50-489c-ae18-71ec96a7095c', E'a1feb048-1f71-44ac-b79b-ba504a5077a7', E'стойкий дефект или избыточное разрастание ткани с патологическим рубцеванием', E'0'),
  (E'b16c0371-4628-4780-a92f-925c25aaa161', E'a1feb048-1f71-44ac-b79b-ba504a5077a7', E'созревание рубца с уменьшением числа капилляров и уплотнением коллагена', E'1'),
  (E'bf922ce6-ad05-4441-a114-e4316cf58ed5', E'a1feb048-1f71-44ac-b79b-ba504a5077a7', E'своевременная эпителизация при сохранном тканевом каркасе', E'2'),
  (E'4d0edd90-467a-4cec-9df7-0193ac12ef7f', E'a1feb048-1f71-44ac-b79b-ba504a5077a7', E'восстановление исходного эпителия без значимого фиброза', E'3'),
  (E'bd32b943-6dac-4f99-b812-465cd9786d1e', E'65c89d3e-da5f-4956-ba0f-43edb1b370e3', E'метаплазия с изменением дифференцировки эпителия и снижением мукоцилиарного клиренса', E'0'),
  (E'b2b6f30a-8cae-4067-a95f-6c15d5a75a6c', E'65c89d3e-da5f-4956-ba0f-43edb1b370e3', E'гиперплазия исходного мерцательного эпителия без изменения его фенотипа', E'1'),
  (E'c7312b08-b62c-4e85-a6a3-9a7f2416f748', E'65c89d3e-da5f-4956-ba0f-43edb1b370e3', E'атрофия бронхиального эпителия без изменения типа клеток', E'2'),
  (E'72da8b8d-3737-45ac-abca-4306ef5f2a0b', E'65c89d3e-da5f-4956-ba0f-43edb1b370e3', E'организация с замещением эпителия плотной соединительной тканью', E'3'),
  (E'27e54b0a-c073-4d5a-be70-f665d850bc9b', E'672a576d-b68a-4d45-855c-c7d2cb2e1729', E'потребность увеличенной массы миокарда в кислороде превышает возможности кровоснабжения, возникают повреждение и фиброз', E'0'),
  (E'18e969d3-0dd9-4bd9-a25b-1f6c710695f5', E'672a576d-b68a-4d45-855c-c7d2cb2e1729', E'капиллярная сеть всегда увеличивается быстрее массы миокарда, вызывая избыточную перфузию', E'1'),
  (E'4262ce42-4005-4d8d-8f8a-f354576cee4f', E'672a576d-b68a-4d45-855c-c7d2cb2e1729', E'гипертрофированные кардиомиоциты превращаются в макрофаги и утрачивают фенотип', E'2'),
  (E'b51bbfb7-4317-4e0c-94aa-06ee66f995f7', E'672a576d-b68a-4d45-855c-c7d2cb2e1729', E'внеклеточный матрикс полностью исчезает, поэтому стенка сердца не может утолщаться', E'3'),
  (E'84e13f6a-e5ef-4a36-a921-d9066ce84b46', E'ea709fa7-9879-47f9-8f9c-976ca0f854cc', E'атрофия всего органа вследствие локального повреждения эпителия', E'3'),
  (E'ca60cc89-1372-418a-ab6b-4858cb66c4eb', E'b091caad-50c8-43ff-a3f5-66e9424f40c7', E'ложная гипертрофия на фоне атрофии функциональных волокон', E'0'),
  (E'257e1490-bba1-4444-8bd7-ea1d649e1005', E'b091caad-50c8-43ff-a3f5-66e9424f40c7', E'истинная рабочая гипертрофия вследствие увеличения диаметра волокон', E'1'),
  (E'38e74e94-693f-491e-9466-6ed959749583', E'b091caad-50c8-43ff-a3f5-66e9424f40c7', E'гиперплазия мышечных волокон за счёт интенсивного митоза', E'2'),
  (E'7440c92f-f384-4abe-85e3-f3641c377b73', E'b091caad-50c8-43ff-a3f5-66e9424f40c7', E'викарная гипертрофия после утраты парного органа', E'3'),
  (E'0c3ed122-589b-465a-a11f-fdf243d4c832', E'63a64097-b754-4c5d-b1d5-5aa03f0a9929', E'избыточное накопление внеклеточного матрикса, преимущественно коллагена, с замещением части паренхимы', E'0'),
  (E'd6eca301-8628-4a21-89e6-961cdc36551f', E'63a64097-b754-4c5d-b1d5-5aa03f0a9929', E'полное восстановление специализированной паренхимы без изменения стромы', E'1'),
  (E'fb0f36ac-a4b3-44ab-b488-feddec881ecf', E'63a64097-b754-4c5d-b1d5-5aa03f0a9929', E'накопление жидкости в межклеточном пространстве без ремоделирования матрикса', E'2'),
  (E'f4538903-4476-4b26-ba69-82e3f739e531', E'63a64097-b754-4c5d-b1d5-5aa03f0a9929', E'увеличение числа эритроцитов в сосудах органа без тканевой перестройки', E'3'),
  (E'b8be7188-e3b6-4e1d-8d23-ea6eff08a611', E'8536da9b-ec01-4f2e-a105-83ac1a53911b', E'организация очага с формированием рубца и возможным стойким снижением функции', E'0'),
  (E'd5d6da33-8bc8-40a5-aee2-171f3855f1a7', E'8536da9b-ec01-4f2e-a105-83ac1a53911b', E'полная реституция за счёт активного деления зрелых специализированных клеток', E'1'),
  (E'6a65a38c-1f91-4d2e-9ee5-b3eb30856971', E'8536da9b-ec01-4f2e-a105-83ac1a53911b', E'обязательное замещение очага зрелой жировой тканью без фиброза', E'2'),
  (E'77a8e5e6-470b-4c28-9367-ababfb31e992', E'8536da9b-ec01-4f2e-a105-83ac1a53911b', E'восстановление исходной архитектоники за счёт превращения фибробластов в паренхиматозные клетки', E'3'),
  (E'b853d2d2-c5a8-4dff-8ae0-eaa4a24c339b', E'd056ee91-31d7-41d6-83a7-9cbdcbcf9f5d', E'инфекция, ишемия, сахарный диабет, недостаточное питание и сохраняющийся некроз', E'0'),
  (E'a8242aea-353f-4613-83e1-469755a7c28e', E'd056ee91-31d7-41d6-83a7-9cbdcbcf9f5d', E'адекватная перфузия, чистые края раны и отсутствие некротических масс', E'1'),
  (E'e1c78abf-e682-45d9-8825-4fe170311a7b', E'd056ee91-31d7-41d6-83a7-9cbdcbcf9f5d', E'сохранность базальной мембраны при отсутствии системных нарушений', E'2'),
  (E'3ef85612-949f-40b9-8f2b-7a57f52786d7', E'c880d40b-d44f-4f5f-aca6-fd771cd995f1', E'Доброкачественную опухоль шванновских клеток.', E'3'),
  (E'6a0cf6ec-0ddf-457f-a072-529981fd2934', E'56252a19-62ac-41cf-9319-c897c75669db', E'Бластемный, эпителиальный и стромальный.', E'0'),
  (E'6a300054-f29c-4416-bd21-6934363c6a0e', E'56252a19-62ac-41cf-9319-c897c75669db', E'Только зрелые адипоциты.', E'1'),
  (E'47561a39-d027-4d89-b71c-61fb1366dfc1', E'56252a19-62ac-41cf-9319-c897c75669db', E'Только меланоциты.', E'2'),
  (E'b599dc62-1bc3-46f4-92bb-81bf16b91159', E'56252a19-62ac-41cf-9319-c897c75669db', E'Только кровенаполненные сосудистые полости.', E'3'),
  (E'599eef8b-b1cf-4fe8-a09c-5d580ef13835', E'701d2ce3-0504-476f-8197-fdb6280f5968', E'Злокачественная опухоль сетчатки, преимущественно раннего детского возраста.', E'0'),
  (E'cfea73a3-bfd7-401f-962a-cc149f19b379', E'701d2ce3-0504-476f-8197-fdb6280f5968', E'Доброкачественная опухоль гладкой мышцы.', E'1'),
  (E'f7a96e55-3690-4a2a-afae-639718040577', E'701d2ce3-0504-476f-8197-fdb6280f5968', E'Сосудистая мальформация кожи.', E'2'),
  (E'9bb03566-a0da-4ec4-864a-732651c62465', E'701d2ce3-0504-476f-8197-fdb6280f5968', E'Опухоль периферического нерва взрослого.', E'3'),
  (E'37fe0d23-f928-4e44-a4d6-df0152c6e2c9', E'a88601be-c8bd-4edf-bd5e-96984e89ffba', E'Лейкокория — белый рефлекс зрачка; возможно также косоглазие.', E'0'),
  (E'bdf33ab5-38b8-40ff-ba9a-667f72a234f5', E'a88601be-c8bd-4edf-bd5e-96984e89ffba', E'Синюшная бляшка на коже туловища.', E'1'),
  (E'0e996c26-0e5b-4441-ad0b-c32df676660d', E'a88601be-c8bd-4edf-bd5e-96984e89ffba', E'Маточные кровотечения.', E'2'),
  (E'154f1209-3c74-4d1e-a08a-cfef3d3e4217', E'a88601be-c8bd-4edf-bd5e-96984e89ffba', E'Пигментная полоска ногтя как типичный единственный симптом.', E'3'),
  (E'dba0ddc4-d1a5-476b-8257-8e8bd4655d3d', E'c5443a93-0151-402b-93a0-04bcf1c8d39a', E'Зародышевый вариант RB1 повышает вероятность ранних множественных и двусторонних опухолей.', E'0'),
  (E'9f773cd7-c44d-4f76-8d1c-910771edc470', E'c5443a93-0151-402b-93a0-04bcf1c8d39a', E'Она всегда односторонняя и не связана с генами.', E'1'),
  (E'35a1323d-5359-423e-aa6f-e431c09acf38', E'c5443a93-0151-402b-93a0-04bcf1c8d39a', E'Она возникает исключительно после травмы глаза.', E'2'),
  (E'66ea7eb1-c39b-474e-8cf2-eedc6a2ec46d', E'c5443a93-0151-402b-93a0-04bcf1c8d39a', E'Она является разновидностью гемангиомы.', E'3'),
  (E'62f17c54-d11f-461e-9dcf-27158a5952f1', E'24286ab1-1728-49b7-b682-8ceea1036fd7', E'Некоторые опухоли имеют эмбриональный характер и связаны с незрелыми тканевыми зачатками.', E'0'),
  (E'd5f07109-ed4d-4013-937d-1a7b124fe4fd', E'24286ab1-1728-49b7-b682-8ceea1036fd7', E'Все детские опухоли мезенхимального происхождения доброкачественны.', E'1'),
  (E'e15f36bb-7125-44be-92ef-9f0959a72f2b', E'24286ab1-1728-49b7-b682-8ceea1036fd7', E'Они возникают только из зрелой соединительной ткани.', E'2'),
  (E'e8f72f06-6886-498d-b58e-a2ef861fe988', E'24286ab1-1728-49b7-b682-8ceea1036fd7', E'Возраст не влияет на спектр опухолей.', E'3'),
  (E'973154a3-6eb5-4416-b685-e5faeb0b687a', E'eab7dd26-4b0d-447f-b2a6-3f84c2017604', E'Морфология клеток и архитектура ткани, при необходимости дополненные иммуногистохимией.', E'0'),
  (E'f02deb7e-74d1-4a67-b972-f93b9fbd18c4', E'eab7dd26-4b0d-447f-b2a6-3f84c2017604', E'Только цвет образования.', E'1'),
  (E'f086c2e6-a08e-4ee6-8bc8-9ad40cef74b3', E'eab7dd26-4b0d-447f-b2a6-3f84c2017604', E'Только возраст пациента.', E'2'),
  (E'bfb684e5-1500-44c5-b6b8-bda112e04ecc', E'eab7dd26-4b0d-447f-b2a6-3f84c2017604', E'Только наличие боли.', E'3');
INSERT INTO public.question_options (id, question_id, option_text, sort_order) VALUES
  (E'c8f2ecdc-3982-4e11-9c71-e6df97813214', E'6f827ef9-c081-4468-94ce-1986affa5c7c', E'Гематогенный, нередко с поражением лёгких.', E'0'),
  (E'f29aa250-5dc2-4852-bc93-c16d697a11a4', E'6f827ef9-c081-4468-94ce-1986affa5c7c', E'Исключительно лимфогенный.', E'1'),
  (E'cda1f0c0-f7b7-422c-876d-9d79affccd51', E'6f827ef9-c081-4468-94ce-1986affa5c7c', E'Только контактное распространение.', E'2'),
  (E'9c8730e7-2017-4cb9-b11d-04dcbb730a43', E'6f827ef9-c081-4468-94ce-1986affa5c7c', E'Метастазы возникают только после операции.', E'3'),
  (E'cd18c186-c97e-4684-9c5e-6d6d10b3f92c', E'64faf5c2-3b2b-42c8-b4f3-7937dfcd77ba', E'Липома — жировая ткань; фиброма — волокнистая соединительная ткань; лейомиома — гладкая мышца.', E'0'),
  (E'0c939067-2393-4b32-a73b-090edd34cff1', E'64faf5c2-3b2b-42c8-b4f3-7937dfcd77ba', E'Липома — эндотелий; фиброма — меланоциты; лейомиома — нервные клетки.', E'1'),
  (E'1aa76046-f544-41fa-94c1-a99087d0c499', E'64faf5c2-3b2b-42c8-b4f3-7937dfcd77ba', E'Гемангиома — адипоциты; шваннома — гладкая мышца; невус — коллаген.', E'2'),
  (E'd45e3c80-44b6-4b3a-88a2-8110f10f99ed', E'64faf5c2-3b2b-42c8-b4f3-7937dfcd77ba', E'Меланома — эндотелий; нефробластома — эпидермис; ретинобластома — хрящ.', E'3'),
  (E'8d8f5f3a-c536-4933-81ba-845827eff8e8', E'54f28afd-dc83-415a-8d01-d6455056c0d2', E'Нужно оценить клеточную атипию, архитектуру и инвазию при морфологическом исследовании.', E'0'),
  (E'c8029531-fdc7-419b-a88d-7593978550eb', E'54f28afd-dc83-415a-8d01-d6455056c0d2', E'Меланома всегда бесцветна и не видна клинически.', E'1'),
  (E'c36b4cd3-be6b-49da-b12f-c9b25a00c42d', E'54f28afd-dc83-415a-8d01-d6455056c0d2', E'Невусы не содержат меланоцитов.', E'2'),
  (E'8dc06601-2960-4d9b-8f9b-4376e281bee1', E'54f28afd-dc83-415a-8d01-d6455056c0d2', E'Все пигментные образования имеют одинаковую структуру.', E'3'),
  (E'6c4f1113-fec4-40c7-b9ce-cf82119dbc26', E'b5e707a0-11ce-41e2-b8aa-fc1665ad652e', E'Гистогенез, морфология, степень дифференцировки и биологическое поведение.', E'0'),
  (E'086237d8-07b0-465c-a51f-9bde163a1527', E'b5e707a0-11ce-41e2-b8aa-fc1665ad652e', E'Только цвет и диаметр.', E'1'),
  (E'456a97d4-7cb8-48b3-9e67-6afd175aca89', E'b5e707a0-11ce-41e2-b8aa-fc1665ad652e', E'Только место обнаружения без микроскопии.', E'2'),
  (E'01eb9dec-9fbf-4874-bfae-9ccc272e97e4', E'b5e707a0-11ce-41e2-b8aa-fc1665ad652e', E'Только наличие боли.', E'3'),
  (E'39c6ea80-495b-4b3b-9e81-20e5dd9848e2', E'46245047-3ce2-42e3-b24b-e1094809770c', E'Интерпретировать панель маркеров вместе с морфологией и клиническими данными.', E'0'),
  (E'33d11ced-7314-4030-816c-33dc50ce75d2', E'46245047-3ce2-42e3-b24b-e1094809770c', E'Считать один маркер достаточным для любого диагноза.', E'1'),
  (E'0c88de0a-566a-4117-a3f4-4b5586a42061', E'46245047-3ce2-42e3-b24b-e1094809770c', E'Использовать её только для измерения диаметра опухоли.', E'2'),
  (E'a847b281-a795-4718-b7fc-a65d5fb541ff', E'46245047-3ce2-42e3-b24b-e1094809770c', E'Определять злокачественность исключительно по цвету ткани.', E'3'),
  (E'63a76959-1c80-406c-b516-a1fe68223b38', E'03ea3084-15aa-493a-b432-88adb1e38bdb', E'Патологический процесс с автономным, нерегулируемым размножением клеток и нарушением их дифференцировки вследствие изменений генетического аппарата.', E'0'),
  (E'be568d96-d5c2-4a9a-a78e-154e18cc5eeb', E'03ea3084-15aa-493a-b432-88adb1e38bdb', E'Любое увеличение объёма органа в ответ на повышенную функциональную нагрузку.', E'1'),
  (E'bbe8d224-b167-431b-8147-316189dcca41', E'03ea3084-15aa-493a-b432-88adb1e38bdb', E'Обратимое накопление жидкости в межклеточном веществе без изменения клеточного размножения.', E'2'),
  (E'1ea707bc-d57d-4836-85f8-84f842045aa8', E'03ea3084-15aa-493a-b432-88adb1e38bdb', E'Восстановление ткани после повреждения с точным воспроизведением исходной структуры.', E'3'),
  (E'73aa9a49-c256-457e-98cc-d0846a2e554a', E'7798d804-4674-4970-90d4-e7fc57a05aac', E'Только сосуды и воспалительный инфильтрат, поскольку опухолевые клетки формируют лишь макроскопический узел.', E'0'),
  (E'ddaed5bc-6da9-4c43-be9f-7be2d42da743', E'7798d804-4674-4970-90d4-e7fc57a05aac', E'Паренхиму из опухолевых клеток и строму, включающую соединительнотканный каркас и сосуды.', E'1'),
  (E'83490faf-9a1f-40ad-a8e6-6791a67a1c12', E'7798d804-4674-4970-90d4-e7fc57a05aac', E'Только эпителиальный пласт и обязательно сохранённую базальную мембрану.', E'2'),
  (E'7002fa90-d92f-4612-8cc1-5c85ecd7ee0a', E'7798d804-4674-4970-90d4-e7fc57a05aac', E'Некротический центр и капсулу, присутствующие во всех опухолях.', E'3'),
  (E'787a8a04-6651-4f7c-ae3a-0a25d6c5031a', E'2615f825-dd7d-4880-b44f-fbee35607643', E'Органоидные состоят только из стромы, а гистиоидные — только из сосудов.', E'0'),
  (E'1c0e11d9-2c11-4d48-8093-550b950ce37d', E'2615f825-dd7d-4880-b44f-fbee35607643', E'Эти названия обозначают исключительно локализацию опухоли, а не особенности её строения.', E'1'),
  (E'7874e48f-db83-4978-8501-e6502a545ced', E'2615f825-dd7d-4880-b44f-fbee35607643', E'Органоидные сохраняют более сложное соотношение паренхимы и стромы, напоминающее орган; в гистиоидных преобладает паренхима, а строма относительно скудна.', E'2'),
  (E'3b74069b-6af5-4e3d-b353-0c2b132629f8', E'2615f825-dd7d-4880-b44f-fbee35607643', E'Органоидные всегда злокачественные, а гистиоидные всегда доброкачественные.', E'3'),
  (E'04481639-1cf0-43f2-93c8-263515047b26', E'00668165-ca4e-4cb4-9df9-5a0f9fc8cdc8', E'Резко увеличенные гиперхромные ядра, многочисленные патологические митозы и выраженный полиморфизм клеток.', E'0'),
  (E'c41715ca-f5af-461a-9426-bbf4e274cdd1', E'00668165-ca4e-4cb4-9df9-5a0f9fc8cdc8', E'Обязательное образование отдалённых метастазов в печени и лёгких.', E'1'),
  (E'46a9fc39-e00d-4f80-8f89-492fc6e88067', E'00668165-ca4e-4cb4-9df9-5a0f9fc8cdc8', E'Увеличение размера каждой клетки при неизменной архитектуре ткани без нарушения роста.', E'2'),
  (E'547e26cf-0e86-4acb-9354-678a02d54dd9', E'00668165-ca4e-4cb4-9df9-5a0f9fc8cdc8', E'Неравномерное развитие железистых структур и стромы, нарушение их обычного взаимного расположения при сохранённом сходстве клеток с исходной тканью.', E'3'),
  (E'3c904f54-4f63-4056-876f-3d956b4c098d', E'9c76ce0a-c256-4093-a552-66572aac4663', E'Полиморфизм клеток и ядер, гиперхромия, увеличение ядерно-цитоплазматического отношения и патологические митозы.', E'0'),
  (E'30ea1636-3088-4afa-b487-9df4a9e85356', E'9c76ce0a-c256-4093-a552-66572aac4663', E'Неравномерная толщина соединительнотканных перегородок при почти нормальных клетках.', E'1'),
  (E'77ba533d-731d-45c5-b0c8-37d006fc6c3d', E'9c76ce0a-c256-4093-a552-66572aac4663', E'Сохранение полярности эпителия и непрерывной базальной мембраны без ядерных изменений.', E'2'),
  (E'be3156ab-d964-4a1b-bef6-314cf1f177be', E'9c76ce0a-c256-4093-a552-66572aac4663', E'Формирование капсулы вокруг узла при отсутствии изменений опухолевых клеток.', E'3'),
  (E'3a1b72c0-8b54-4bec-97ce-02733aa87b3c', E'e02b53cd-28ea-4089-94a7-020741b84974', E'Эти типы различают исключительно по цвету опухоли на разрезе.', E'0'),
  (E'5048e423-014d-481d-bb39-edf31620fd1d', E'e02b53cd-28ea-4089-94a7-020741b84974', E'При экспансивном росте узел оттесняет окружающие ткани и обычно имеет относительно чёткую границу; при инфильтрирующем опухолевые клетки внедряются между тканевыми структурами и разрушают их.', E'1'),
  (E'7e2fb936-cc37-41a6-b905-d1c36149b745', E'e02b53cd-28ea-4089-94a7-020741b84974', E'Экспансивный рост всегда означает быстрое метастазирование, а инфильтрирующий — отсутствие метастазов.', E'2'),
  (E'e3293a24-4b90-42f6-bce1-e1310017f85a', E'e02b53cd-28ea-4089-94a7-020741b84974', E'Экспансивный рост бывает только в эпителии, а инфильтрирующий — только в соединительной ткани.', E'3'),
  (E'8b82d579-3f08-4466-9b2a-24fba6307ffe', E'bf35b774-f86c-45f7-8fdb-a4f73f53ec32', E'Периневральное распространение вдоль нервных оболочек.', E'0'),
  (E'8fbad668-ede6-43ea-8220-4d27897bc59a', E'bf35b774-f86c-45f7-8fdb-a4f73f53ec32', E'Имплантационное распространение по серозной оболочке.', E'1'),
  (E'6640ea32-85da-46cc-a96e-24a3566029d2', E'bf35b774-f86c-45f7-8fdb-a4f73f53ec32', E'Экзофитный рост в просвет органа.', E'2'),
  (E'3de71e0a-0079-414e-9dcb-734dcf4637fe', E'bf35b774-f86c-45f7-8fdb-a4f73f53ec32', E'Эндофитный инфильтрирующий рост в толщу стенки.', E'3'),
  (E'1c48e4b2-5526-4864-8afe-a8b01963cef3', E'64ec5c12-f0ed-453d-949d-d5d0c8aef162', E'Она всегда инкапсулирована, никогда не рецидивирует и не нарушает функцию органов.', E'0'),
  (E'82443ae7-507c-477d-934b-a48789a3d60e', E'64ec5c12-f0ed-453d-949d-d5d0c8aef162', E'Для неё обязательно характерны выраженный клеточный атипизм и прорастание сосудов.', E'1'),
  (E'3508966c-a3ce-461e-945b-89db78350732', E'64ec5c12-f0ed-453d-949d-d5d0c8aef162', E'Она по определению не может увеличиваться после удаления раздражающего фактора.', E'2'),
  (E'f3f20475-ad37-48db-940e-52cfbf71a44b', E'64ec5c12-f0ed-453d-949d-d5d0c8aef162', E'Она обычно состоит из достаточно дифференцированных клеток, часто растёт экспансивно и не метастазирует, хотя её локализация может быть опасной.', E'3'),
  (E'ae894fe3-6781-4473-95de-9a35ee859829', E'b8304fd1-d0eb-42ca-8c10-cce840f693b7', E'Инфильтративное разрушение окружающих тканей с потенциалом метастазирования.', E'0'),
  (E'7ac8abdb-f7dc-444a-8586-6f51b75e5f12', E'b8304fd1-d0eb-42ca-8c10-cce840f693b7', E'Большой диаметр узла независимо от его структуры.', E'1'),
  (E'd98f2079-0b19-4eeb-be1e-9434fa29a587', E'b8304fd1-d0eb-42ca-8c10-cce840f693b7', E'Наличие плотной стромы и белесоватого цвета на разрезе.', E'2'),
  (E'672e5207-d06e-4296-aea7-69461d1d80c4', E'b8304fd1-d0eb-42ca-8c10-cce840f693b7', E'Наличие тканевого атипизма при полностью сохранённых базальной мембране и полярности.', E'3'),
  (E'e562a6be-6159-4264-bfe8-041a5cd680d1', E'db15c315-a26a-4e09-9fa6-8ae864be9d7c', E'Метастазирование — это появление опухоли на прежнем месте после её удаления.', E'0'),
  (E'24db1dfd-4c61-43cd-a8fd-f185f10b9e8d', E'db15c315-a26a-4e09-9fa6-8ae864be9d7c', E'Лимфогенный — по лимфатическим сосудам и узлам; гематогенный — по кровеносным сосудам; имплантационный — по серозным поверхностям.', E'1'),
  (E'76884828-5d81-4652-bdec-c26f5988cd3a', E'db15c315-a26a-4e09-9fa6-8ae864be9d7c', E'Лимфогенный — по нервным оболочкам; гематогенный — только в соседнюю ткань; имплантационный — исключительно через костный мозг.', E'2'),
  (E'7c581218-74fa-4738-abfb-1bdc933392c5', E'db15c315-a26a-4e09-9fa6-8ae864be9d7c', E'Все злокачественные опухоли распространяются только гематогенно.', E'3'),
  (E'79d71645-fd95-4cb2-8c27-1baf02ab964e', E'5803f405-bebb-4140-8a87-eedd26183633', E'Первичное появление нескольких независимых опухолевых очагов в одном органе.', E'0'),
  (E'2fe7ee87-5cc8-492f-9bf4-65761be89c33', E'5803f405-bebb-4140-8a87-eedd26183633', E'Увеличение лимфатического узла из-за воспаления без опухолевых клеток.', E'1'),
  (E'87f7fd39-b295-4b99-894c-be243230e8c2', E'5803f405-bebb-4140-8a87-eedd26183633', E'Повторное возникновение опухоли в области первичного очага после лечения, например из оставшихся опухолевых клеток.', E'2'),
  (E'461bf5ee-264d-4d0d-8fb5-2b5f1098b684', E'5803f405-bebb-4140-8a87-eedd26183633', E'Образование любой дочерней опухоли в отдалённом органе.', E'3'),
  (E'23fa5803-392a-4e58-93f1-fc01c8719461', E'c25f43b6-2cf9-47a7-ad9f-6ed1a987ffe9', E'Изолированное кратковременное снижение аппетита без изменения массы тела и мышечной ткани.', E'0'),
  (E'e48e9ef7-6013-4857-8b88-9d95d7e0b788', E'c25f43b6-2cf9-47a7-ad9f-6ed1a987ffe9', E'Увеличение мышечной массы вследствие усиленного синтеза белка.', E'1'),
  (E'f82d2225-be80-4d7a-81a9-79139ecbcdf2', E'c25f43b6-2cf9-47a7-ad9f-6ed1a987ffe9', E'Локальный отёк вокруг опухоли без системных изменений.', E'2'),
  (E'e9e0f6ce-5796-4e48-8066-48eab1e3b18b', E'c25f43b6-2cf9-47a7-ad9f-6ed1a987ffe9', E'Прогрессирующее истощение с потерей мышечной и жировой массы, слабостью и нарушениями обмена веществ.', E'3'),
  (E'de385de0-0caa-48d4-aa77-a6a562e6e565', E'20b600f1-adfb-4f62-8402-cf8f981002fc', E'Системное нарушение, связанное с опухолью, но не объясняемое непосредственно локальным сдавлением или метастазом, например гормоноподобным действием опухолевых продуктов.', E'0'),
  (E'3cff9838-4134-4c70-990c-f885014dc572', E'20b600f1-adfb-4f62-8402-cf8f981002fc', E'Боль исключительно из-за непосредственного прорастания опухоли в нерв.', E'1'),
  (E'6155c530-717c-43ae-91b2-6fd3c8f3748c', E'20b600f1-adfb-4f62-8402-cf8f981002fc', E'Кровотечение из язвенной поверхности опухоли вследствие разрушения местных сосудов.', E'2'),
  (E'9a36e82a-fe16-4749-b94f-9c746a892c26', E'20b600f1-adfb-4f62-8402-cf8f981002fc', E'Увеличение органа только из-за механического заполнения его полости опухолевым узлом.', E'3'),
  (E'70b75b4e-4c36-4baf-b7f3-28e6583b81e0', E'177cd05a-c585-4580-9af3-709a3c261183', E'Образование рубца → обязательное превращение любого рубца в рак.', E'0'),
  (E'ff6e8ada-d57d-4f4d-aece-95302e9d5379', E'177cd05a-c585-4580-9af3-709a3c261183', E'Нарушение регуляции регенерации → предопухолевые изменения, включая гиперплазию и дисплазию → малигнизация клеток → опухолевый зачаток и дальнейшая прогрессия.', E'1'),
  (E'40ae445a-fb3e-4ae3-9a0f-5425e04109e1', E'177cd05a-c585-4580-9af3-709a3c261183', E'Метастазирование → полное восстановление исходной ткани → исчезновение генетических нарушений.', E'2'),
  (E'1d3c82a7-fd83-46a0-b7c7-3aa311565371', E'177cd05a-c585-4580-9af3-709a3c261183', E'Капсула → некроз → нормальная дифференцировка → физиологическая регенерация.', E'3'),
  (E'bbe071e3-94e7-4fd2-b904-cf01e5e3ed19', E'e2947111-bb70-4bfd-8191-adc3ec628c13', E'Определение только анатомической глубины инвазии без выяснения типа клеток.', E'0'),
  (E'9d3909ab-0f5a-4c7c-a2cb-999e08ba2ca3', E'e2947111-bb70-4bfd-8191-adc3ec628c13', E'Оценка цвета опухоли на разрезе без микроскопии.', E'1'),
  (E'c4c93a16-51c6-4e54-9207-79ca4b7ef177', E'e2947111-bb70-4bfd-8191-adc3ec628c13', E'Установление ткани или клеточной линии, из которой опухоль произошла, с учётом её морфологической дифференцировки.', E'2'),
  (E'f18acfc5-f53e-4206-b05a-421e1cc6eb06', E'e2947111-bb70-4bfd-8191-adc3ec628c13', E'Описание только скорости увеличения опухоли по дням.', E'3'),
  (E'b1e8844a-8b82-4ec3-b1ca-95ba304a826a', E'8777347a-f13f-480f-9a01-7692b6304a50', E'Только доброкачественные, пограничные и злокачественные опухоли трёх типов роста.', E'0'),
  (E'497db029-bfc7-45cf-8aa4-05de1a79fa0b', E'8777347a-f13f-480f-9a01-7692b6304a50', E'Эпителиальные, инфекционные, воспалительные, сосудистые, дегенеративные, обменные и травматические процессы.', E'1'),
  (E'dd02f87d-440f-4c83-9bba-fb5bdad2c2f5', E'8777347a-f13f-480f-9a01-7692b6304a50', E'Опухоли кожи, лёгких, печени, сердца, мозга, костей и почек без учёта гистогенеза.', E'2'),
  (E'31be5580-c697-49d0-82f4-0151018e7ffe', E'8777347a-f13f-480f-9a01-7692b6304a50', E'Органонеспецифические эпителиальные; органоспецифические эпителиальные; мезенхимальные; меланинобразующей ткани; нервной системы и оболочек мозга; системы крови; тератомы.', E'3'),
  (E'8164297e-213e-4c6b-9d2d-992ea1847ffc', E'00d9f5a1-09e2-498c-b2af-70008e6015a7', E'Папиллома из плоского или переходного покровного эпителия.', E'0'),
  (E'4b0b6b4a-3764-46d2-8290-96ac9f9e2293', E'00d9f5a1-09e2-498c-b2af-70008e6015a7', E'Почечно-клеточный рак, тесно связанный с эпителием почечных канальцев.', E'1'),
  (E'1c9e8256-b869-4e28-89dd-daa05e90427c', E'00d9f5a1-09e2-498c-b2af-70008e6015a7', E'Фолликулярный рак щитовидной железы из тиреоидного эпителия.', E'2'),
  (E'e8b4a2b5-af93-4313-958c-c27eaac021d2', E'00d9f5a1-09e2-498c-b2af-70008e6015a7', E'Гормонально-активная опухоль из клеток C щитовидной железы.', E'3'),
  (E'6a378b7b-11ec-4691-a195-3618ad3b584a', E'8e2c9f36-0991-403f-81de-44e66b77686c', E'Только коллагеновые пучки без эпителиальной паренхимы.', E'0'),
  (E'1ec41bff-505d-41d5-b5e4-c73ef1cb4f8e', E'8e2c9f36-0991-403f-81de-44e66b77686c', E'Сосочковые разрастания покровного эпителия с сохранением общей полярности и стромальными выростами, содержащими сосуды.', E'1'),
  (E'c9fee665-e0c0-4577-971c-3905632e5f55', E'8e2c9f36-0991-403f-81de-44e66b77686c', E'Инвазивные тяжи атипичных клеток, разрушающие базальную мембрану и проникающие в строму.', E'2'),
  (E'd23ad313-e188-417a-8aaa-8c60b6e76eed', E'8e2c9f36-0991-403f-81de-44e66b77686c', E'Сплошные пласты анапластических клеток без признаков эпителиальной дифференцировки.', E'3'),
  (E'cac6ab4b-a103-4480-a54d-71526c727587', E'654b5e7e-1813-4329-ae25-b5d5ab6c785f', E'Опухоль из гладкомышечной ткани, образующая переплетающиеся пучки.', E'0'),
  (E'38061001-a834-4819-b851-05e3d5b8029d', E'654b5e7e-1813-4329-ae25-b5d5ab6c785f', E'Поверхностный дефект эпителия без автономного опухолевого размножения.', E'1'),
  (E'14c135c8-3cde-43dd-afec-939360c4ee8e', E'654b5e7e-1813-4329-ae25-b5d5ab6c785f', E'Доброкачественная эпителиальная опухоль железистого типа, в которой клетки формируют железы или сосочковые структуры и обычно сохраняют базальную мембрану.', E'2'),
  (E'0c343ccb-371a-49f8-8cd6-834c422c85d7', E'654b5e7e-1813-4329-ae25-b5d5ab6c785f', E'Злокачественная опухоль, обязательно прорастающая сосуды и дающая метастазы.', E'3'),
  (E'fc11ab28-82b0-4463-92ec-5de90eb1f2b2', E'1c6c9423-df6d-438f-8b53-86535a05a7b2', E'При carcinoma in situ опухолевые клетки уже обязательно находятся в кровеносных сосудах.', E'0'),
  (E'94e40307-1de5-4889-a8c2-8d90b3a2f46d', E'1c6c9423-df6d-438f-8b53-86535a05a7b2', E'При инвазивном раке базальная мембрана всегда полностью сохранена.', E'1'),
  (E'ff0a2af2-36d2-49c7-ae42-9bd431e2a17e', E'1c6c9423-df6d-438f-8b53-86535a05a7b2', E'Carcinoma in situ означает доброкачественную папиллому без клеточного атипизма.', E'2'),
  (E'ee7f6cb4-2845-4cbb-8bd1-7fc380e8b354', E'1c6c9423-df6d-438f-8b53-86535a05a7b2', E'При carcinoma in situ атипичные эпителиальные клетки занимают эпителиальный пласт, но не прорастают через базальную мембрану в подлежащую строму.', E'3');
INSERT INTO public.question_options (id, question_id, option_text, sort_order) VALUES
  (E'9481b350-525f-4c0e-8683-21416106f914', E'2f9bf124-fa86-4041-a9a6-48429f509b45', E'Гнёзда и тяжи атипичных плоских клеток, внедряющиеся в подлежащую ткань, с возможным формированием раковых жемчужин.', E'0'),
  (E'2a4f1101-c1bf-44db-8c11-128d9315801f', E'2f9bf124-fa86-4041-a9a6-48429f509b45', E'Правильные железы, выстланные однотипным эпителием, без инвазии.', E'1'),
  (E'be28375d-de9f-4b20-b519-949143de48b6', E'2f9bf124-fa86-4041-a9a6-48429f509b45', E'Сосочковые структуры с сохранённой полярностью и неповреждённой базальной мембраной.', E'2'),
  (E'b7b72f93-7d9f-49cc-ac8b-71c7f3be2b35', E'2f9bf124-fa86-4041-a9a6-48429f509b45', E'Пласты меланоцитов с обязательным синтезом меланина.', E'3'),
  (E'2dec7533-bee1-4134-aa3a-839b1d829445', E'96a6a6a2-568c-4a8e-8c0c-c6f34a01de3a', E'Различие сводится только к цвету на разрезе, а микроскопическая структура у них всегда одинаковая.', E'0'),
  (E'28d1ddba-7570-47e4-9c47-bd070b68d660', E'96a6a6a2-568c-4a8e-8c0c-c6f34a01de3a', E'Аденокарцинома имеет злокачественную эпителиальную атипию и инвазивный рост, утрачивая нормальные границы структур и прорастая окружающую ткань.', E'1'),
  (E'9793e79c-83cf-485d-8a74-a221bc2b306a', E'96a6a6a2-568c-4a8e-8c0c-c6f34a01de3a', E'Аденокарцинома обязательно состоит из зрелых клеток без митозов и не может метастазировать.', E'2'),
  (E'64b62cc0-0c37-4616-be83-ad250bedbf27', E'96a6a6a2-568c-4a8e-8c0c-c6f34a01de3a', E'Аденома всегда является опухолью соединительной ткани, а аденокарцинома — гладкой мышцы.', E'3'),
  (E'd6e78f59-0533-4b89-b562-a95fdad85480', E'b3b535e2-703f-4cda-89aa-df61c0e4d002', E'Опухоль из эндотелия, образующая заполненные кровью полости.', E'0'),
  (E'c47db174-874b-4cd9-b39a-3a2f620eb364', E'b3b535e2-703f-4cda-89aa-df61c0e4d002', E'Папиллома с выраженным ороговением поверхности без слизеобразования.', E'1'),
  (E'b073f768-f66b-433e-a9c0-8eee92bb7434', E'b3b535e2-703f-4cda-89aa-df61c0e4d002', E'Злокачественная эпителиальная опухоль, клетки которой продуцируют большое количество слизи, в которой могут располагаться опухолевые клетки.', E'2'),
  (E'03be9eaf-efb3-4c2b-8e23-8c14fb45cb75', E'b3b535e2-703f-4cda-89aa-df61c0e4d002', E'Доброкачественная опухоль из зрелых адипоцитов с жировыми вакуолями.', E'3'),
  (E'7e221d76-b92c-4737-88fe-1d4c93508e8a', E'3f6a3d78-bf73-432c-866d-df19aff261d3', E'Рак in situ всегда больше по размеру, чем инвазивный рак.', E'0'),
  (E'403e3582-ce59-4f34-aa15-0870b5213090', E'3f6a3d78-bf73-432c-866d-df19aff261d3', E'Инвазивный рак ограничивается просветом протока, а рак in situ прорастает жировую клетчатку.', E'1'),
  (E'42298fc5-36ac-4b02-8fbc-c25ee30ccae3', E'3f6a3d78-bf73-432c-866d-df19aff261d3', E'Эти формы отличаются только наличием боли и не различаются гистологически.', E'2'),
  (E'041d127d-5ea6-4de8-a9ea-b0d595c90dec', E'3f6a3d78-bf73-432c-866d-df19aff261d3', E'При раке in situ опухолевые клетки остаются внутри протоков или долек; при инвазивном раке они проникают за пределы исходных эпителиальных структур в окружающую строму.', E'3'),
  (E'9c5faf93-760a-4f9e-90a9-4e98919f3b81', E'4a7279fa-92b9-4911-9c0e-ca41fd6d90e9', E'Экзематозное поражение соска и ареолы с опухолевыми клетками Педжета в эпидермисе, связанное с раком эпителия протоков молочной железы.', E'0'),
  (E'12b16315-8a5e-447b-8d53-3c04b20386b3', E'4a7279fa-92b9-4911-9c0e-ca41fd6d90e9', E'Доброкачественная сосудистая опухоль соска, не связанная с эпителием протоков.', E'1'),
  (E'b4a22a97-5ac3-4145-a749-3ae9305c15d6', E'4a7279fa-92b9-4911-9c0e-ca41fd6d90e9', E'Только воспаление кожи соска без опухолевых клеток и без связи с протоками.', E'2'),
  (E'50d05d4d-8357-4a64-87de-e8a3fc059afb', E'4a7279fa-92b9-4911-9c0e-ca41fd6d90e9', E'Гладкомышечная опухоль, формирующая узел в ареоле.', E'3'),
  (E'c8d57d54-1288-4e8d-a62e-9a2388dca02e', E'66a83541-b76d-466c-939e-4770343253e9', E'Состоит исключительно из поверхностных сосочков без вовлечения ткани железы.', E'0'),
  (E'8659c06e-682f-4488-8be5-cd07cc1e5e89', E'66a83541-b76d-466c-939e-4770343253e9', E'Может формировать плотный узел с белесоватыми тяжами, проникающими в окружающую жировую ткань, либо диффузно уплотнять железу с плохо различимыми границами.', E'1'),
  (E'fc02e6ce-44ee-4b32-b1c0-08ae1c31f883', E'66a83541-b76d-466c-939e-4770343253e9', E'Всегда представляет собой тонкостенную кисту с прозрачной жидкостью и гладкой внутренней поверхностью.', E'2'),
  (E'3fe331e2-a650-4aa0-9aab-849cb80e4a0b', E'66a83541-b76d-466c-939e-4770343253e9', E'Обязательно растёт только на ножке в просвет полого органа.', E'3'),
  (E'c27a7c2a-c03b-45aa-999b-bcdc6d8c1377', E'8b87f1dd-3fdc-466f-ad1d-f618c73dd4f9', E'Переходно-клеточная папиллома почечной лоханки.', E'0'),
  (E'91ce2682-8acd-403e-ad07-8e7ac0b818ca', E'8b87f1dd-3fdc-466f-ad1d-f618c73dd4f9', E'Плоскоклеточная папиллома кожи.', E'1'),
  (E'8a13e9b5-20ce-49c8-95fa-5946f93a838d', E'8b87f1dd-3fdc-466f-ad1d-f618c73dd4f9', E'Почечно-клеточный рак.', E'2'),
  (E'c6f928db-b9f0-4177-8594-43ad13e2603c', E'8b87f1dd-3fdc-466f-ad1d-f618c73dd4f9', E'Нефробластома как наиболее частая опухоль взрослого возраста.', E'3'),
  (E'86dbd890-e333-46b3-82ad-819ec0b23b24', E'9c6ae6e5-d81c-45cc-8ac2-0458a0a9296f', E'Множественные тонкие сосочки в мочевом пузыре без опухоли в почке.', E'0'),
  (E'32019657-a6b9-48ab-b565-8b2a039a3378', E'9c6ae6e5-d81c-45cc-8ac2-0458a0a9296f', E'Равномерное диффузное уменьшение обеих почек без опухолевого узла.', E'1'),
  (E'514edfc8-51c2-4b5e-9104-a4ea091094ab', E'9c6ae6e5-d81c-45cc-8ac2-0458a0a9296f', E'Поверхностная бородавчатая опухоль эпидермиса с выраженным ороговением.', E'2'),
  (E'ccda49e9-4d60-4146-b3fb-dfc46b2171bd', E'9c6ae6e5-d81c-45cc-8ac2-0458a0a9296f', E'Узловая опухоль паренхимы почки, нередко желтоватая на разрезе из-за липидов, с возможными очагами кровоизлияния и некроза.', E'3'),
  (E'22da7892-4679-43c8-ac27-3e3dd212f66c', E'1c573ebb-44a4-4bc7-b6fc-9aeb6a4f1450', E'Почечно-клеточный рак возникает из эпителия канальцев паренхимы, тогда как большинство опухолей лоханки связано с уротелием её выстилки.', E'0'),
  (E'9720feb0-b524-4f43-a187-65be3cc0a79b', E'1c573ebb-44a4-4bc7-b6fc-9aeb6a4f1450', E'Обе опухоли всегда происходят из одного и того же эпителия канальцев и имеют идентичное строение.', E'1'),
  (E'dddaf158-8c02-49f6-a3ec-626581070a20', E'1c573ebb-44a4-4bc7-b6fc-9aeb6a4f1450', E'Рак лоханки развивается только из сосудов, а рак паренхимы — только из нервных клеток.', E'2'),
  (E'bef31d89-cc7d-4cd4-ade3-d4e857aecec6', E'1c573ebb-44a4-4bc7-b6fc-9aeb6a4f1450', E'Рак паренхимы по определению доброкачественный, а опухоль лоханки всегда представляет собой метастаз.', E'3'),
  (E'4a73d78c-080c-4a7e-902c-77312a698832', E'42a3b501-ed13-4510-9a94-05a88aa1ddb1', E'Цвет коллоида сам по себе позволяет надёжно определить наличие метастазов.', E'0'),
  (E'70c57c5d-953e-4551-8b8f-43e7fe2dd514', E'42a3b501-ed13-4510-9a94-05a88aa1ddb1', E'Доказанная капсулярная и/или сосудистая инвазия поддерживает диагноз фолликулярного рака; одной только похожей фолликулярной архитектуры недостаточно.', E'1'),
  (E'7d3405ce-2793-424e-a4f6-27b89db0c891', E'42a3b501-ed13-4510-9a94-05a88aa1ddb1', E'Наличие фолликулов автоматически доказывает злокачественность.', E'2'),
  (E'4408ed7e-7476-46a9-a44a-bc117c403704', E'42a3b501-ed13-4510-9a94-05a88aa1ddb1', E'Любая капсула вокруг узла означает рак.', E'3'),
  (E'56b35b69-7243-4fb3-99ee-059ee8323d9c', E'fabba7bb-224a-4377-ab7e-2d0ca3fe1c3b', E'Он всегда развивается только у пожилых людей и почти немедленно разрушает все ткани шеи.', E'0'),
  (E'9a2f1c7c-98ab-46ee-91b1-cd026727bec1', E'fabba7bb-224a-4377-ab7e-2d0ca3fe1c3b', E'Он представляет собой доброкачественную аденому, не способную к инвазии.', E'1'),
  (E'ce62fd08-8be2-4499-b4e9-9521aef36ef7', E'fabba7bb-224a-4377-ab7e-2d0ca3fe1c3b', E'Это частая форма рака щитовидной железы, для которой характерны папиллярные структуры и сравнительно частое лимфогенное распространение в регионарные лимфатические узлы.', E'2'),
  (E'54a47a89-a3e5-4d0a-bad7-b25f0f30867a', E'fabba7bb-224a-4377-ab7e-2d0ca3fe1c3b', E'Он происходит из C-клеток и определяется амилоидом как обязательным признаком.', E'3'),
  (E'0e974aad-2e86-4072-a531-499ddb297633', E'14b755e9-ce5c-4f6d-8e44-7119b2a06073', E'Тиреоглобулин как специфический продукт только C-клеток.', E'0'),
  (E'a7210a57-b439-4414-85ed-2a21cec7f357', E'14b755e9-ce5c-4f6d-8e44-7119b2a06073', E'Инсулин.', E'1'),
  (E'43287487-c644-40c7-a47a-7e6be27c06f2', E'14b755e9-ce5c-4f6d-8e44-7119b2a06073', E'Меланин.', E'2'),
  (E'fd996ebe-9581-4424-a428-24cc6749bbf6', E'14b755e9-ce5c-4f6d-8e44-7119b2a06073', E'Кальцитонин.', E'3'),
  (E'85562f07-895c-48c5-9606-ae40fd1f6e58', E'b7d67509-86bb-429d-9f1f-7f8b4addefd0', E'Опухоль из C-клеток с амилоидом в строме, производным белковых продуктов опухолевых клеток.', E'0'),
  (E'a68444bd-7b65-4ac1-aa7b-eaf9289fcc1b', E'b7d67509-86bb-429d-9f1f-7f8b4addefd0', E'Ороговевающие раковые жемчужины в тяжах плоского эпителия.', E'1'),
  (E'dbdf8c12-ef1d-4027-b926-a0195e0f7b76', E'b7d67509-86bb-429d-9f1f-7f8b4addefd0', E'Только зрелые коллоидные фолликулы без клеточной атипии и инвазии.', E'2'),
  (E'46e97d30-4bab-41a6-826f-2ae6c45e9259', E'b7d67509-86bb-429d-9f1f-7f8b4addefd0', E'Сосочковые выросты, обязательно ограниченные базальной мембраной и без опухолевой атипии.', E'3'),
  (E'2dacb259-e197-4863-8f12-88df5edb1c62', E'35f47150-6595-4c46-8a78-2edad4a3810e', E'Папиллома эпидермиса, которая не затрагивает ткани шеи.', E'0'),
  (E'2af54a02-1150-476c-a3a1-58c55ab2daa0', E'35f47150-6595-4c46-8a78-2edad4a3810e', E'Недифференцированная злокачественная опухоль с выраженным клеточным полиморфизмом и обычно агрессивным местным ростом.', E'1'),
  (E'6d5867f0-33eb-44e5-b9af-12667e233714', E'35f47150-6595-4c46-8a78-2edad4a3810e', E'Доброкачественная инкапсулированная опухоль из однотипных фолликулов без инвазии.', E'2'),
  (E'fb1ca89c-ac4e-4dfc-9138-5e9f074be99d', E'35f47150-6595-4c46-8a78-2edad4a3810e', E'Опухоль, состоящая исключительно из зрелых адипоцитов.', E'3'),
  (E'2829ace2-fb26-4ffd-b974-c9969e5ad0b1', E'34568bac-bd25-4ee8-9261-e5333a1e4274', E'Опухолевые клетки, распространяющиеся исключительно по кровеносным сосудам.', E'0'),
  (E'976fbd1d-0f24-4661-ae96-686b151a93d9', E'34568bac-bd25-4ee8-9261-e5333a1e4274', E'Строма из зрелой гладкой мышечной ткани как единственный компонент.', E'1'),
  (E'a364f3a4-e00a-4ca9-8d40-3f9ae0042859', E'34568bac-bd25-4ee8-9261-e5333a1e4274', E'Сосочковое разрастание эпителия, обычно с сохранением полярности и без инвазии в дерму.', E'2'),
  (E'520d0cc9-8fc3-4bde-9031-c520e78530b8', E'34568bac-bd25-4ee8-9261-e5333a1e4274', E'Атипичные клетки, прорастающие через базальную мембрану и образующие инвазивные тяжи.', E'3'),
  (E'c6e32cb2-3d63-48f5-a2fd-caaf85adf8c3', E'28cdb4a6-688c-4b7d-84a4-09aaf0c9e902', E'Абсолютно доброкачественную папиллому, которая не разрушает окружающие ткани.', E'0'),
  (E'b6fe0430-0e6e-47a6-81c6-ba935925fef5', E'28cdb4a6-688c-4b7d-84a4-09aaf0c9e902', E'Опухоль, для которой обязательны ранние многочисленные отдалённые метастазы.', E'1'),
  (E'2db6b03e-e387-4817-92ec-c07e1ed4ca31', E'28cdb4a6-688c-4b7d-84a4-09aaf0c9e902', E'Опухоль только из меланоцитов, содержащих меланин.', E'2'),
  (E'83f6dd31-0d33-4066-a5ec-c922c595dc49', E'28cdb4a6-688c-4b7d-84a4-09aaf0c9e902', E'Опухоль с местно-деструирующим ростом и склонностью к рецидивам, при этом метастазирование крайне редко.', E'3'),
  (E'cb64cc59-b095-48da-aeaa-3c20a050e720', E'9168ff2e-aefe-44b3-b146-cedbc1d74063', E'Гнёзда и тяжи мелких базофильных клеток, напоминающих базальные клетки эпидермиса, с местным инвазивным ростом.', E'0'),
  (E'296aacb1-ab56-48e7-ac1e-eb1107ba34fa', E'9168ff2e-aefe-44b3-b146-cedbc1d74063', E'Железистые просветы, выстланные полностью однотипными клетками, без инвазии.', E'1'),
  (E'b66b84a7-ab51-4f06-9e93-a3ec4b26a0d5', E'9168ff2e-aefe-44b3-b146-cedbc1d74063', E'Крупные зрелые жировые клетки с одной вакуолью и тонкой цитоплазмой.', E'2'),
  (E'135377ae-7ac3-47ab-be67-e37bc3871e81', E'9168ff2e-aefe-44b3-b146-cedbc1d74063', E'Пласты меланоцитов с обязательным наличием меланинового пигмента во всех клетках.', E'3'),
  (E'7133e49e-c41c-44c0-a053-0fbacf77ee09', E'b2964d65-c0b9-4537-bbec-0a2aabc7132f', E'Сирингоаденома и гидраденома являются синонимами меланомы.', E'0'),
  (E'8cd1fc98-e899-4d6c-b748-0ab6ffe32f6f', E'b2964d65-c0b9-4537-bbec-0a2aabc7132f', E'Трихоэпителиома — структуры волосяных фолликулов; сирингоаденома — эпителий протоков потовых желёз; гидраденома — секреторный эпителий потовых желёз.', E'1'),
  (E'987e69c5-2bad-42fc-b15b-51c7c7034778', E'b2964d65-c0b9-4537-bbec-0a2aabc7132f', E'Трихоэпителиома — эндотелий сосудов; сирингоаденома — меланоциты; гидраденома — гладкая мышца.', E'2'),
  (E'730953e0-da6c-4599-b64f-163f55cc6cd0', E'b2964d65-c0b9-4537-bbec-0a2aabc7132f', E'Все три опухоли происходят из клеток крови и обязательно метастазируют.', E'3'),
  (E'87d0f752-f300-4319-9e78-ea095ebf4c14', E'b434c161-1fb3-4e6e-8188-44b2561d3246', E'Отсутствие клеточной атипии и сохранение границы эпителия со стромой.', E'0'),
  (E'd7b8edda-68ed-4edd-a9b8-ea279297a872', E'b434c161-1fb3-4e6e-8188-44b2561d3246', E'Наличие зрелых потовых протоков без инвазивного компонента.', E'1'),
  (E'68ce2b12-b505-4a0b-bdf8-0438f8b61073', E'b434c161-1fb3-4e6e-8188-44b2561d3246', E'Нарушение базальной мембраны с проникновением атипичных плоских клеток в дерму, возможно с ороговением.', E'2'),
  (E'ef2c6cd2-a4eb-4262-87d5-d3ab614aaaa1', E'b434c161-1fb3-4e6e-8188-44b2561d3246', E'Только сосочковая поверхность при сохранённой полярности эпителия.', E'3'),
  (E'83e537a3-ad64-48fb-8b8c-02e97f768240', E'a658a61b-51dc-4757-9f22-2cb61a66ce20', E'Высокая дифференцировка всегда означает доброкачественность и отсутствие инвазии.', E'0'),
  (E'26443ba9-f867-4f59-9a11-bb5d56bb6745', E'a658a61b-51dc-4757-9f22-2cb61a66ce20', E'Низкая дифференцировка означает, что опухоль не может быть эпителиальной.', E'1'),
  (E'10ebf948-7e48-4eb1-a3ad-7e029d21f370', E'a658a61b-51dc-4757-9f22-2cb61a66ce20', E'Дифференцировка определяется только размером опухолевого узла.', E'2'),
  (E'8bc882f9-dbca-4f24-a711-b7426f9fdcd2', E'a658a61b-51dc-4757-9f22-2cb61a66ce20', E'Чем больше опухолевые клетки и структуры напоминают исходную ткань, тем выше дифференцировка; сама по себе хорошая дифференцировка не исключает злокачественности.', E'3'),
  (E'980ac96a-74d1-4dd8-a15b-bc00479651cc', E'b0c60c58-9090-45ca-9189-c9f2c0f2e5b3', E'Они происходят из соединительной, жировой, мышечной, сосудистой, костной или хрящевой ткани.', E'0'),
  (E'd8bae8ab-217d-4ca8-a23c-b2c0aa549c70', E'b0c60c58-9090-45ca-9189-c9f2c0f2e5b3', E'Они всегда развиваются из покровного эпителия.', E'1'),
  (E'4239b75f-a50a-4657-af4c-d0f89dfa2b43', E'b0c60c58-9090-45ca-9189-c9f2c0f2e5b3', E'Они обязательно происходят из меланоцитов.', E'2'),
  (E'4f9fc18a-2d5e-423e-8a7b-9f05c3e40e29', E'b0c60c58-9090-45ca-9189-c9f2c0f2e5b3', E'Они формируются исключительно из зрелых нейронов ЦНС.', E'3'),
  (E'8d59d76a-0b23-4e90-8bde-5416f569b3c4', E'b11b1ac0-628d-4488-9770-bfb52f054c11', E'Экспансивный рост, относительная отграниченность и отсутствие метастазов.', E'0'),
  (E'2c970fad-a6f2-4ce5-8ca6-67472f5e0ef7', E'b11b1ac0-628d-4488-9770-bfb52f054c11', E'Инфильтрация тканей, выраженная атипия и частые патологические митозы.', E'1'),
  (E'069d3f85-4862-484d-a7f0-78f2b7b6d970', E'b11b1ac0-628d-4488-9770-bfb52f054c11', E'Раннее гематогенное метастазирование и опухолевый некроз как обязательные признаки.', E'2'),
  (E'4152e8a9-2ddb-4313-b092-0819ee78a273', E'b11b1ac0-628d-4488-9770-bfb52f054c11', E'Прорастание сосудов при любом размере опухоли.', E'3'),
  (E'aaf2f5cb-f6af-48d4-99ef-5b003a681e82', E'82e309e4-d659-443e-8e16-21b05a6fbc4f', E'Инфильтративный рост и потенциальная способность к метастазированию.', E'0'),
  (E'e1d1c6a1-b195-41cc-9eb9-97d60547e253', E'82e309e4-d659-443e-8e16-21b05a6fbc4f', E'Медленный рост с чёткой капсулой без инвазии.', E'1'),
  (E'2ecd0f02-e7ae-47cc-8826-3879fe6a81fa', E'82e309e4-d659-443e-8e16-21b05a6fbc4f', E'Полное сходство клеток с нормальной тканью и отсутствие митозов.', E'2'),
  (E'd7860a0e-248f-4a73-a826-12797f36ca8e', E'82e309e4-d659-443e-8e16-21b05a6fbc4f', E'Обязательное расположение только в коже.', E'3'),
  (E'f5c190de-6fac-45f3-a893-5c83a5b08a1e', E'a6376c05-9f9c-49ce-bcca-24bb61b6aa5a', E'Из зрелой волокнистой соединительной ткани, коллагена и фибробластоподобных клеток.', E'0'),
  (E'78e743b8-61f1-4195-98da-1434797c35c0', E'a6376c05-9f9c-49ce-bcca-24bb61b6aa5a', E'Из кровенаполненных сосудистых полостей.', E'1'),
  (E'c9e93ebf-860d-4fbc-9b76-e3036b30effd', E'a6376c05-9f9c-49ce-bcca-24bb61b6aa5a', E'Из атипичных меланоцитов с инвазивным ростом.', E'2'),
  (E'1bc1915e-0799-475e-b164-c4efa2254f4c', E'a6376c05-9f9c-49ce-bcca-24bb61b6aa5a', E'Из пучков гладкомышечных клеток как единственного компонента.', E'3'),
  (E'cdc20cde-49e2-440e-b17f-9f35b222cbc9', E'8028d285-5e77-4bb2-b464-b71508d32197', E'Преобладание толстых коллагеновых пучков при сравнительно небольшом количестве клеток.', E'0'),
  (E'3c72363e-3c72-4326-a9f0-6fbcf8643db1', E'8028d285-5e77-4bb2-b464-b71508d32197', E'Преобладание расширенных сосудистых лакун.', E'1'),
  (E'7988e77c-5b52-43eb-bd9f-afe3a54cf330', E'8028d285-5e77-4bb2-b464-b71508d32197', E'Пласты атипичных меланоцитов с многочисленными митозами.', E'2'),
  (E'afdded49-7cd3-4082-b534-33083a045798', E'8028d285-5e77-4bb2-b464-b71508d32197', E'Дольки зрелых адипоцитов с тонкими перегородками.', E'3');
INSERT INTO public.question_options (id, question_id, option_text, sort_order) VALUES
  (E'61cdc51a-e6dd-4ea3-a798-d884cfc30d3d', E'49204c65-3d61-4be8-b16d-7aeacfbe0f82', E'Относительно большим количеством клеток и рыхлого матрикса при меньшем преобладании плотного коллагена.', E'0'),
  (E'9be8c0a5-6fa9-469a-bac0-f2b7224a2cc9', E'49204c65-3d61-4be8-b16d-7aeacfbe0f82', E'Обязательным наличием метастазов.', E'1'),
  (E'7905a14f-8ee4-4104-b975-cfc0db7a3621', E'49204c65-3d61-4be8-b16d-7aeacfbe0f82', E'Полным отсутствием соединительнотканного компонента.', E'2'),
  (E'dbabcda3-3356-4328-9eb1-c5d6be2dd468', E'49204c65-3d61-4be8-b16d-7aeacfbe0f82', E'Происхождением из меланоцитов.', E'3'),
  (E'9566cf5a-96b7-4843-8566-65fe94306c34', E'814c8f2f-d794-4add-aef1-3e8121e9b61f', E'Переплетающиеся пучки зрелых гладкомышечных клеток без выраженной атипии.', E'0'),
  (E'4fcce22c-afd0-4be6-b136-1a5fe41636c2', E'814c8f2f-d794-4add-aef1-3e8121e9b61f', E'Сосудистые каналы, выстланные эндотелием.', E'1'),
  (E'ad12b92b-5966-4f7a-8df2-b746725e1165', E'814c8f2f-d794-4add-aef1-3e8121e9b61f', E'Зрелые адипоциты, разделённые тонкими перегородками.', E'2'),
  (E'e24edda8-85aa-478a-acba-ae2bee13c1df', E'814c8f2f-d794-4add-aef1-3e8121e9b61f', E'Гнёзда невусных клеток в эпидермисе.', E'3'),
  (E'34d4e645-1169-4bf2-ada5-471189b413f4', E'686b5114-4d43-4167-b993-9a13ffacde47', E'Узлами в миометрии, вызывающими кровотечения, боль или компрессию соседних органов.', E'0'),
  (E'3228224e-4426-4e3d-8281-bb9a829efac1', E'686b5114-4d43-4167-b993-9a13ffacde47', E'Обязательным метастазированием в лёгкие.', E'1'),
  (E'cefb3880-3bab-4eaf-a269-1558ae25e649', E'686b5114-4d43-4167-b993-9a13ffacde47', E'Диффузным замещением миометрия меланоцитами.', E'2'),
  (E'b972975f-cf44-4764-854e-b34b24b2ee3c', E'686b5114-4d43-4167-b993-9a13ffacde47', E'Только синюшными сосудистыми полостями без мышечной ткани.', E'3'),
  (E'178a3e58-fc61-44a4-9383-206b1b5f38ec', E'f2d7a41e-4b03-4365-a83c-2989dd487039', E'Степень атипии, митотическая активность, характер некроза и инвазивный рост.', E'0'),
  (E'fcff29fc-4cda-471b-95c5-426da7773db6', E'f2d7a41e-4b03-4365-a83c-2989dd487039', E'Только диаметр узла.', E'1'),
  (E'afa11b96-da85-4136-a02b-54192176cf64', E'f2d7a41e-4b03-4365-a83c-2989dd487039', E'Сам факт наличия гладкомышечных клеток.', E'2'),
  (E'27ce9bd6-27c8-4e2c-a45a-3b71c69c6ba8', E'f2d7a41e-4b03-4365-a83c-2989dd487039', E'Только цвет на разрезе.', E'3'),
  (E'f4ca18a2-ecf6-4542-a60a-17f2315c48a1', E'989881d1-adf1-4fe4-a170-012d65c863c6', E'Рабдомиома.', E'0'),
  (E'8ef08fa0-71f9-4c27-b832-a9e82c28e967', E'989881d1-adf1-4fe4-a170-012d65c863c6', E'Лейомиома.', E'1'),
  (E'da78fe9b-47fd-4f5c-a5ab-44fbc4b165df', E'989881d1-adf1-4fe4-a170-012d65c863c6', E'Фиброма.', E'2'),
  (E'2f528269-032e-4c47-a08c-8b9aa0c9397e', E'989881d1-adf1-4fe4-a170-012d65c863c6', E'Гемангиома.', E'3'),
  (E'ce74b46d-57bc-4f60-aef6-28b3b0ed1804', E'65d0e037-387d-49d6-83aa-d9492c052ad7', E'Гематогенный, в том числе с метастазами в лёгкие.', E'0'),
  (E'63447a6f-ce9b-4c33-8a36-a4809a281c57', E'65d0e037-387d-49d6-83aa-d9492c052ad7', E'Только лимфогенный, без отдалённых метастазов.', E'1'),
  (E'eb7b4705-268f-4bc4-854f-a30487e26078', E'65d0e037-387d-49d6-83aa-d9492c052ad7', E'Только контактный, без проникновения в сосуды.', E'2'),
  (E'397eb63d-82b9-4244-b641-a26f479d313b', E'65d0e037-387d-49d6-83aa-d9492c052ad7', E'Метастазирование исключительно после хирургического удаления.', E'3'),
  (E'004204c5-a3d8-4c39-a106-2e6f1517b2ea', E'e99ddb32-5886-46ab-a7d2-2b3940692f17', E'Из сосудистых каналов или пространств, выстланных эндотелием.', E'0'),
  (E'42cdba4c-c600-490b-8d6b-4b046e8ebf3b', E'e99ddb32-5886-46ab-a7d2-2b3940692f17', E'Из зрелых гладкомышечных пучков без просветов.', E'1'),
  (E'bbc44301-3791-40e9-a033-4d09bdd08b6a', E'e99ddb32-5886-46ab-a7d2-2b3940692f17', E'Из гнёзд меланоцитов.', E'2'),
  (E'4f4d140e-1278-4ba4-96cb-69f9b1f5e270', E'e99ddb32-5886-46ab-a7d2-2b3940692f17', E'Из коллагеновых пучков без сосудистого компонента.', E'3'),
  (E'4c2da218-486f-4bf1-baa1-379c4e68015c', E'4e6f74cb-dc50-4879-be49-5b890a9ec966', E'Капиллярная содержит мелкие сосудистые каналы, кавернозная — крупные расширенные кровенаполненные пространства.', E'0'),
  (E'55be7709-b133-4553-af28-67d9afd1a107', E'4e6f74cb-dc50-4879-be49-5b890a9ec966', E'Капиллярная всегда злокачественна, кавернозная всегда метастазирует.', E'1'),
  (E'886fabc2-dc3d-4344-9b4e-f1b61f73bccc', E'4e6f74cb-dc50-4879-be49-5b890a9ec966', E'Кавернозная состоит из меланоцитов, капиллярная — из нейронов.', E'2'),
  (E'2ecefb1f-d297-4dfc-bec5-8976a88cba44', E'4e6f74cb-dc50-4879-be49-5b890a9ec966', E'Обе состоят только из коллагена.', E'3'),
  (E'5bbbf4b7-3029-43e8-923d-3d53c4603892', E'397c9c0f-e8e1-416e-ab54-b98850386100', E'Кровотечение, изъязвление или нарушение функции из-за сдавления соседних структур.', E'0'),
  (E'4a8f49e0-2a77-4924-89c3-a684003f218f', E'397c9c0f-e8e1-416e-ab54-b98850386100', E'Неизбежное превращение в меланому.', E'1'),
  (E'6c1920b3-4e34-47a2-bbd1-4c6729483bce', E'397c9c0f-e8e1-416e-ab54-b98850386100', E'Обязательное формирование костной ткани.', E'2'),
  (E'a1a0fbcb-b5b4-4e4d-aa99-a3757dbbf2c3', E'397c9c0f-e8e1-416e-ab54-b98850386100', E'Полное отсутствие клинических последствий при любом размере.', E'3'),
  (E'03349c30-92e1-435a-a353-fb020fc51ad5', E'1cd6dc23-d087-4b21-a78d-d65341528d28', E'Невусные клетки меланоцитарного происхождения, часто образующие гнёзда в эпидермисе и/или дерме.', E'0'),
  (E'ea10842e-a061-48b2-8e92-9027610bebe2', E'1cd6dc23-d087-4b21-a78d-d65341528d28', E'Эндотелиальные клетки сосудов.', E'1'),
  (E'68e97710-20af-4e3d-bcd1-c35af90cf87e', E'1cd6dc23-d087-4b21-a78d-d65341528d28', E'Фибробласты с массивным синтезом коллагена.', E'2'),
  (E'1121bdd9-0a17-4b4b-a1fd-17a7bf542029', E'1cd6dc23-d087-4b21-a78d-d65341528d28', E'Гладкомышечные клетки, формирующие пучки.', E'3'),
  (E'fa5152a5-f4fa-4b86-88cd-881d29c99c4f', E'9c8314f8-e973-4231-ab51-b98a7db4bd20', E'Асимметрия, неоднородная окраска, неровные границы или заметная эволюция образования.', E'0'),
  (E'e7db6296-0acc-42e1-ab20-fb0392da4131', E'9c8314f8-e973-4231-ab51-b98a7db4bd20', E'Симметрия и стабильная равномерная окраска на протяжении многих лет.', E'1'),
  (E'a28a7b2e-dc02-4474-9e35-0af903981d25', E'9c8314f8-e973-4231-ab51-b98a7db4bd20', E'Отсутствие изменений при длительном наблюдении как единственный критерий.', E'2'),
  (E'48d14cb2-a970-4c9e-9e71-b178c4d3eb30', E'9c8314f8-e973-4231-ab51-b98a7db4bd20', E'Расположение исключительно в подкожной клетчатке.', E'3'),
  (E'28abf36f-7683-4d9c-82a0-e65961de8333', E'df98d849-91fe-4d61-9d75-1d8330e09db1', E'Атипичная пролиферация меланоцитов с нарушением созревания и признаками инвазивного роста.', E'0'),
  (E'0dac7872-c60e-409a-ab7d-fbe437ec7179', E'df98d849-91fe-4d61-9d75-1d8330e09db1', E'Только коричневый цвет без оценки клеток.', E'1'),
  (E'6840b6be-5e1e-45a7-b6ac-603c1795f74d', E'df98d849-91fe-4d61-9d75-1d8330e09db1', E'Плотный коллагеновый матрикс без меланоцитов.', E'2'),
  (E'e8e30a51-9747-45aa-aee0-667a90fe09b6', E'df98d849-91fe-4d61-9d75-1d8330e09db1', E'Однородные сосудистые каналы без атипии.', E'3'),
  (E'1aafa934-62a9-4d40-b21f-6058c0aa92d2', E'5f5abeb2-ff10-4cb9-85b5-97b8e23a0277', E'Проникновение опухолевых клеток в глубину дермы и подлежащих тканей.', E'0'),
  (E'9d9d4f3e-6049-4382-804e-39ee6774f193', E'5f5abeb2-ff10-4cb9-85b5-97b8e23a0277', E'Распространение только по поверхности эпидермиса без инвазии.', E'1'),
  (E'051ee8a0-2e7b-4af8-81fb-5eccecbc6b3b', E'5f5abeb2-ff10-4cb9-85b5-97b8e23a0277', E'Полное восстановление нормального эпидермиса.', E'2'),
  (E'e52a11aa-61cb-4ab7-b32b-e00799ce38e3', E'5f5abeb2-ff10-4cb9-85b5-97b8e23a0277', E'Формирование сосудистых полостей.', E'3'),
  (E'd451e44e-435b-4b33-a4cf-45d717cffd63', E'bde8fdde-55a2-4436-85dc-d00d902b490f', E'Она измеряет вертикальную толщину опухоли и связана с прогнозом и риском метастазирования.', E'0'),
  (E'33af89c8-cf4d-491c-ae04-b5594adc12cf', E'bde8fdde-55a2-4436-85dc-d00d902b490f', E'Она измеряет только площадь окрашенного участка.', E'1'),
  (E'44e148fc-2332-4bdd-95b3-5fa41a71796f', E'bde8fdde-55a2-4436-85dc-d00d902b490f', E'Она показывает только число сосудов.', E'2'),
  (E'359f45b6-d53b-4442-9b91-dfa6f7b7fd2f', E'bde8fdde-55a2-4436-85dc-d00d902b490f', E'Она применяется для различения фибромы и липомы.', E'3'),
  (E'056ac44d-5406-4cd7-97e0-4523e695126e', E'40a83285-fd3a-4c52-877f-0ad9c3dcbd4f', E'Невус обычно доброкачественен, меланома — злокачественная опухоль меланоцитов с инвазивным потенциалом.', E'0'),
  (E'9952214b-3750-4464-83ac-82ab14e7209c', E'40a83285-fd3a-4c52-877f-0ad9c3dcbd4f', E'Любой невус обязательно превращается в меланому.', E'1'),
  (E'0c318c9a-ca12-445a-8b7b-808ac96bb549', E'40a83285-fd3a-4c52-877f-0ad9c3dcbd4f', E'Меланома всегда беспигментная.', E'2'),
  (E'075000cf-3c22-47e6-95a7-9b1ab0e9ff58', E'40a83285-fd3a-4c52-877f-0ad9c3dcbd4f', E'Они различаются только диаметром.', E'3'),
  (E'7e5639ba-82d8-4f5c-b15b-9f0a2827e18d', E'd8778e9f-15d9-48d8-b931-cffcd06a282c', E'Шваннома.', E'0'),
  (E'63a29c5a-7742-4186-8ca7-18b3b8eb4ba1', E'd8778e9f-15d9-48d8-b931-cffcd06a282c', E'Лейомиома.', E'1'),
  (E'e41a02e8-c51e-4159-b782-aac544d01088', E'd8778e9f-15d9-48d8-b931-cffcd06a282c', E'Гемангиома.', E'2'),
  (E'de989cae-1049-4ca6-9c63-5e6eeee1876a', E'd8778e9f-15d9-48d8-b931-cffcd06a282c', E'Липома.', E'3'),
  (E'58c9a3b5-4099-487b-9d0b-fc2fc2271db2', E'6155bde6-37e8-4f96-86f6-ede3c3f3b14d', E'Плотные клеточные участки и более рыхлые зоны; в плотных участках могут быть тельца Верокаи.', E'0'),
  (E'e2c907c0-0917-497b-941e-916246db27e6', E'6155bde6-37e8-4f96-86f6-ede3c3f3b14d', E'Только зрелые адипоциты.', E'1'),
  (E'47f70370-d555-4d94-8061-3582f8fa1c26', E'6155bde6-37e8-4f96-86f6-ede3c3f3b14d', E'Гнёзда меланоцитов с эпидермальным распространением.', E'2'),
  (E'1a28471c-fe8b-48fb-81c9-8774cce61d15', E'6155bde6-37e8-4f96-86f6-ede3c3f3b14d', E'Крупные сосудистые полости без клеточных компонентов.', E'3'),
  (E'26bb31d9-37b7-47b9-b20b-26a46df1c78c', E'8711bf53-d2f2-4a5e-b557-656ca7dda594', E'Имеет смешанный клеточный состав и может включать нервные волокна, проходящие через опухоль.', E'0'),
  (E'29893153-3897-4526-9f16-b15a3c132652', E'8711bf53-d2f2-4a5e-b557-656ca7dda594', E'Состоит только из эндотелия.', E'1'),
  (E'1fcb5e0e-db6b-460a-9543-c549d3365946', E'8711bf53-d2f2-4a5e-b557-656ca7dda594', E'Всегда является злокачественной опухолью.', E'2'),
  (E'5b37bd36-da8a-4e55-a660-b84f9daae6bd', E'8711bf53-d2f2-4a5e-b557-656ca7dda594', E'Состоит исключительно из зрелых жировых клеток.', E'3'),
  (E'9eec6da4-893c-40fc-ab68-502d660df153', E'b31f562b-154c-4fd2-a7f0-41a8f52fa4e0', E'Нейрофиброматозом 1-го типа.', E'0'),
  (E'4376ec41-8cfc-4968-9728-8250a69cfbbb', E'b31f562b-154c-4fd2-a7f0-41a8f52fa4e0', E'Изолированным обычным невусом.', E'1'),
  (E'a836f737-a007-4527-91d0-33064fe0a771', E'b31f562b-154c-4fd2-a7f0-41a8f52fa4e0', E'Лейомиомой матки во всех случаях.', E'2'),
  (E'19c6521f-532d-4a1d-a737-97c395db9f95', E'b31f562b-154c-4fd2-a7f0-41a8f52fa4e0', E'Капиллярной гемангиомой как обязательной причиной.', E'3'),
  (E'c6a013c9-d685-4cc4-8e6a-52ad39714113', E'11f43a61-8335-446c-8c00-4af7ad736d77', E'Инфильтрация, выраженная атипия, высокая митотическая активность и возможный некроз.', E'0'),
  (E'82ccdd58-dd61-4c6b-92ca-4b669d210116', E'11f43a61-8335-446c-8c00-4af7ad736d77', E'Чёткая отграниченность и отсутствие митозов.', E'1'),
  (E'9678b755-bc3a-4474-ba51-3e3b0720d21c', E'11f43a61-8335-446c-8c00-4af7ad736d77', E'Зрелые адипоциты без атипии.', E'2'),
  (E'32582d1e-86b4-4daf-aab6-17e1b8505a26', E'11f43a61-8335-446c-8c00-4af7ad736d77', E'Коллагеновые волокна без опухолевой клеточной пролиферации.', E'3'),
  (E'81121cd7-68a5-494a-8b48-e5be5018d8f0', E'4f761bfc-f12c-43a9-85ad-218c40197494', E'Они могут сдавливать или раздражать нервные волокна.', E'0'),
  (E'657183da-74a7-4e87-9870-6b74812486a8', E'4f761bfc-f12c-43a9-85ad-218c40197494', E'Они обязательно синтезируют меланин.', E'1'),
  (E'2e120163-5cca-45f9-860a-6a257c3e9e46', E'4f761bfc-f12c-43a9-85ad-218c40197494', E'Они всегда вызывают гемолиз.', E'2'),
  (E'ad4a2df4-39ca-4c41-aeb6-615c516641cd', E'4f761bfc-f12c-43a9-85ad-218c40197494', E'Они действуют только через эпителиальную метаплазию.', E'3'),
  (E'adf7dc91-479f-4992-af47-0015d683a162', E'a228eb13-9893-4294-a17c-0b24cb7af796', E'Их течение зависит от конкретного типа: некоторые гемангиомы пролиферируют после рождения и затем регрессируют, другие сосудистые аномалии ведут себя иначе.', E'0'),
  (E'ecc64ef6-d915-4f1d-9a23-11b6758bef86', E'a228eb13-9893-4294-a17c-0b24cb7af796', E'Все они являются саркомами.', E'1'),
  (E'20c7d736-f21f-4cbe-858b-120cba64b89d', E'a228eb13-9893-4294-a17c-0b24cb7af796', E'Каждое образование обязательно регрессирует без наблюдения.', E'2'),
  (E'b4ab779f-5953-46ca-95ab-4bd36dec92a9', E'a228eb13-9893-4294-a17c-0b24cb7af796', E'Они никогда не нарушают функцию органов.', E'3'),
  (E'088f738b-ccea-420b-be6a-bee97fbd704c', E'4a109bcc-2b98-4bb3-9cb1-3db07493b227', E'Становится заметной в первые недели жизни, проходит фазу роста и может постепенно инволюционировать.', E'0'),
  (E'77944fd1-3777-4d61-a636-72d5f2fb44e2', E'4a109bcc-2b98-4bb3-9cb1-3db07493b227', E'Всегда полностью сформирована при зачатии и не меняется.', E'1'),
  (E'abecaa15-d362-4678-8b12-2bbd01c30096', E'4a109bcc-2b98-4bb3-9cb1-3db07493b227', E'Является синонимом меланомы у младенцев.', E'2'),
  (E'c9df65f8-4efb-4842-a66a-3a4fc62c0750', E'4a109bcc-2b98-4bb3-9cb1-3db07493b227', E'Состоит исключительно из гладкомышечных пучков.', E'3'),
  (E'e4516fe1-4f36-42e1-99e4-18c6a1172dc1', E'e15608a9-1d5c-4b1c-bcf3-8d75f290fb40', E'Даже доброкачественная опухоль может нарушать дыхание или зрение из-за локализации.', E'0'),
  (E'db0fa780-1506-42ef-9f8e-47e29b5e3396', E'e15608a9-1d5c-4b1c-bcf3-8d75f290fb40', E'Такая локализация сама по себе доказывает метастазирование.', E'1'),
  (E'8ab8b314-28d6-4894-9d1d-b442982b0117', E'e15608a9-1d5c-4b1c-bcf3-8d75f290fb40', E'Доброкачественные образования не могут нарушать функции органов.', E'2'),
  (E'958572d1-c46a-42a4-8776-f71ad48b1e57', E'e15608a9-1d5c-4b1c-bcf3-8d75f290fb40', E'Единственное осложнение — превращение в фиброму.', E'3'),
  (E'bcfe58d2-258d-4f1e-9210-6d003418e6bf', E'c880d40b-d44f-4f5f-aca6-fd771cd995f1', E'Злокачественную эмбриональную опухоль почки, преимущественно встречающуюся у детей.', E'0'),
  (E'8df27b12-05c9-4431-8f5f-678d58fb8ba7', E'c880d40b-d44f-4f5f-aca6-fd771cd995f1', E'Доброкачественную опухоль сосудов кожи.', E'1'),
  (E'81bd2d76-ea9c-4322-ad55-75f2bead1e24', E'c880d40b-d44f-4f5f-aca6-fd771cd995f1', E'Меланоцитарную опухоль сетчатки.', E'2'),
  (E'31c6d869-9d1f-4fa8-8acb-1c1c558fe1e6', E'6eeab34c-3521-4c3a-b423-680587191222', E'Иммунодефициты, реакции гиперчувствительности, аутоиммунные заболевания и амилоидоз', E'0');
INSERT INTO public.question_options (id, question_id, option_text, sort_order) VALUES
  (E'9d705782-09c2-4ab0-b1bc-f8197c3b3f1a', E'6eeab34c-3521-4c3a-b423-680587191222', E'Только первичные иммунодефициты и аллергические реакции немедленного типа', E'1'),
  (E'05974465-c23e-4f63-a698-97e76ad7ed08', E'6eeab34c-3521-4c3a-b423-680587191222', E'Только аутоиммунные заболевания и опухоли лимфоидной ткани', E'2'),
  (E'fb017d6f-9464-4181-9943-21556540ba1d', E'6eeab34c-3521-4c3a-b423-680587191222', E'Гиперплазия лимфоузлов, спленомегалия и любые инфекционные болезни', E'3'),
  (E'09b78e2d-27e0-4b90-9b3d-8c88b5429c34', E'd056ee91-31d7-41d6-83a7-9cbdcbcf9f5d', E'своевременное удаление некроза при контролируемой инфекции и достаточном кровоснабжении', E'3'),
  (E'b3d9cc93-b8f6-4403-9945-f5eaead288d1', E'5de3a7a1-c24c-457f-8af4-d5d11fa13735', E'физиологическая, репаративная и патологическая', E'0'),
  (E'3cb85bcf-b19f-472a-a9e2-911520470ee2', E'5de3a7a1-c24c-457f-8af4-d5d11fa13735', E'клеточная и внутриклеточная', E'1'),
  (E'9f922a5b-f8d8-421e-95e3-1f34ac6dde26', E'5de3a7a1-c24c-457f-8af4-d5d11fa13735', E'полная реституция и неполная субституция', E'2'),
  (E'fe735722-b33b-49d9-89fd-3927e184eeb4', E'a9a95b68-fbe8-4001-abaf-1da0ea627370', E'Аденоматозный полип толстой кишки', E'0'),
  (E'7314237b-7964-4f58-9c7f-68b732a474ad', E'a9a95b68-fbe8-4001-abaf-1da0ea627370', E'Гиперпластический полип', E'1'),
  (E'f42dc7ac-8d49-46e6-b53c-048c90ddcd36', E'a9a95b68-fbe8-4001-abaf-1da0ea627370', E'Аденоматозный полип желудка', E'2'),
  (E'e4b48e0c-de5f-4649-8c0f-87b8227e382f', E'a9a95b68-fbe8-4001-abaf-1da0ea627370', E'Дивертикул Меккеля', E'3'),
  (E'44c23ae3-0a92-425c-a057-d969a782a1ef', E'5de3a7a1-c24c-457f-8af4-d5d11fa13735', E'ишемическая, компрессионная и дисгормональная', E'3');



--
-- Data for Name: question_trash; Type: TABLE DATA; Schema: public; Owner: -
--

-- question_trash: 0 rows in source dump


--
-- Data for Name: questions; Type: TABLE DATA; Schema: public; Owner: -
--

-- Imported 403 rows into public.questions
INSERT INTO public.questions (id, section, block, topic_id, prompt, image_path, is_exam, is_published, created_by, created_at, updated_at) VALUES
  (E'6f28a422-a177-43c0-8d6f-41f9cf127085', E'theory', E'general', E'4', E'Что характерно для хронического венозного застоя в лёгких?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:44.14104+00', E'2026-10-25 20:31:44.453585+00'),
  (E'7c07057a-982d-418f-abe5-c26649151f65', E'theory', E'general', E'1', E'Какое определение наиболее точно соответствует понятию «дистрофия»?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:17.325996+00', E'2026-10-25 15:51:17.72579+00'),
  (E'056d6796-3437-49aa-a2e1-8b83cb6e7f5e', E'theory', E'general', E'1', E'По каким основным признакам классифицируют дистрофии?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:17.827166+00', E'2026-10-25 15:51:18.159807+00'),
  (E'c0edcfb3-1a0f-4254-98f7-1ada8b44efe7', E'theory', E'general', E'1', E'Какой вариант НЕ относится к четырём основным механизмам морфогенеза дистрофий?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:18.253536+00', E'2026-10-25 15:51:18.665833+00'),
  (E'7c368354-ed4d-4e5c-9f5a-235b531a3ad1', E'macro', E'specific', E'15', E'Пациентка 67 лет. Страдала от прогрессирующего запора, вздутия живота, слабости и потери аппетита. Определи патологию.', E'questions/cc3558f5-32b6-459a-bfc7-6498568e3113.jpg', E'f', E't', NULL, E'2026-10-22 18:28:18.627227+00', E'2026-10-22 18:28:19.668073+00'),
  (E'a9a95b68-fbe8-4001-abaf-1da0ea627370', E'macro', E'specific', E'15', E'Определи патологию.', E'questions/34d6520a-0e51-4ed2-bad3-bc8b74b6e410.jpg', E'f', E't', NULL, E'2026-10-22 18:43:02.531354+00', E'2026-10-26 22:23:59.077147+00'),
  (E'e42319a0-9585-4068-aba3-dd3b082d9ee4', E'theory', E'general', E'1', E'Какой механизм подразумевает распад ультраструктур клеток и межклеточного вещества?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:18.774319+00', E'2026-10-25 15:51:19.140967+00'),
  (E'6b241cf2-b8f8-4400-80f0-a360cb7cd3a5', E'theory', E'general', E'1', E'Какой признак наиболее характерен для гиалиново-капельной дистрофии при световой микроскопии?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:19.244441+00', E'2026-10-25 15:51:19.577325+00'),
  (E'20294443-8ae8-45ac-8630-9e2a2f99fa78', E'theory', E'general', E'1', E'Каков исход гиалиново-капельной дистрофии?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:19.68006+00', E'2026-10-25 15:51:20.023346+00'),
  (E'6ba889cb-f5b3-40ba-8f03-8a2594888776', E'theory', E'specific', E'15', E'Какой морфологический признак лежит в основе болезни Гиршпрунга?', NULL, E'f', E't', NULL, E'2026-10-22 19:05:34.314265+00', E'2026-10-22 19:05:35.137502+00'),
  (E'6cad8663-d0e1-4068-9759-8c8aaedb4af6', E'theory', E'general', E'1', E'Тельца Мэллори в гепатоцитах связаны прежде всего с:', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:20.11813+00', E'2026-10-25 15:51:20.437303+00'),
  (E'73fb80e6-f5bc-475b-88df-beec0eaab466', E'theory', E'general', E'1', E'Какое утверждение о гидропической дистрофии верно?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:20.537673+00', E'2026-10-25 15:51:20.840053+00'),
  (E'df8943c1-eeb5-4388-b407-1221c464d8d5', E'theory', E'specific', E'15', E'Какое изменение характерно для ранней стадии ишемического повреждения кишечника?', NULL, E'f', E't', NULL, E'2026-10-22 19:12:01.66653+00', E'2026-10-22 19:12:02.349407+00'),
  (E'3747c271-34e2-45d6-b17f-2f632a551caf', E'theory', E'general', E'1', E'Что может быть неблагоприятным исходом выраженной гидропической дистрофии?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:20.941567+00', E'2026-10-25 15:51:21.251059+00'),
  (E'18bc9b49-e108-4248-abaf-5e169098cbea', E'theory', E'specific', E'15', E'Что характерно для ангиодисплазии кишечника?', NULL, E'f', E't', NULL, E'2026-10-22 19:12:41.462169+00', E'2026-10-22 19:12:41.936717+00'),
  (E'23d9a0da-077c-4473-94a6-498563bb8648', E'theory', E'general', E'1', E'При какой патологии гидропическая дистрофия гепатоцитов особенно характерна?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:21.343534+00', E'2026-10-25 15:51:21.644896+00'),
  (E'28ce84b0-e67a-43aa-b044-346551156287', E'theory', E'general', E'1', E'Роговая дистрофия — это:', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:21.734667+00', E'2026-10-25 15:51:22.041037+00'),
  (E'2e2a902e-9d14-4769-9cde-75ae1a45f2d0', E'theory', E'general', E'1', E'Какое сочетание «изменение — пример» правильное?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:22.154727+00', E'2026-10-25 15:51:22.511466+00'),
  (E'f7e90987-c01e-46c5-9f9a-f09022ff1fb2', E'theory', E'specific', E'15', E'Какова причина формирования дивертикула Меккеля?', NULL, E'f', E't', NULL, E'2026-10-22 19:11:23.099183+00', E'2026-10-24 21:35:39.149828+00'),
  (E'565e6acc-a394-41b7-88eb-22d04203af0e', E'theory', E'general', E'1', E'Почему длительно существующая лейкоплакия имеет клиническое значение?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:22.617212+00', E'2026-10-25 15:51:22.93345+00'),
  (E'bda40b0d-d4e6-496e-a2d0-ca19d0e38a76', E'theory', E'specific', E'15', E'Что характерно для атрезии кишечника?', NULL, E'f', E't', NULL, E'2026-10-22 19:06:37.382784+00', E'2026-10-24 21:35:47.61257+00'),
  (E'81612ea5-581a-4671-9a40-dfc9df29c95a', E'macro', E'specific', E'15', E'Определи патологию.', E'questions/ecb319d1-77f3-469a-a250-98e65e001501.jpg', E'f', E't', NULL, E'2026-10-23 10:54:09.657298+00', E'2026-10-24 21:52:55.794701+00'),
  (E'2feb4438-9993-4275-b215-2f668234aa1a', E'theory', E'general', E'1', E'Как характеризуется ихтиоз в контексте роговой дистрофии?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:23.027434+00', E'2026-10-25 15:51:23.338016+00'),
  (E'565fc072-c314-493e-be35-44f815112ea2', E'theory', E'general', E'1', E'Какой метод применяют для выявления нейтральных липидов в ткани?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:23.434035+00', E'2026-10-25 15:51:23.760459+00'),
  (E'9cf4ef72-6718-4de8-8272-11b9f08f0cdb', E'theory', E'general', E'1', E'Почему при обычной гистологической обработке жировая дистрофия выглядит как вакуоли в цитоплазме?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:23.863463+00', E'2026-10-25 15:51:24.194474+00'),
  (E'f6dd8320-e2a2-488e-afac-39b4a1fefb51', E'theory', E'general', E'1', E'Как обычно выглядит печень при выраженной жировой дистрофии макроскопически?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:24.290812+00', E'2026-10-25 15:51:24.612261+00'),
  (E'6ecdd62b-b2ea-49da-9926-e08e6caa0777', E'theory', E'general', E'1', E'Какой механизм НЕ относится к причинам жировой дистрофии печени?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:24.698707+00', E'2026-10-25 15:51:25.026732+00'),
  (E'607a3ec4-af76-41b1-bd56-180f3eaaaaa5', E'theory', E'general', E'1', E'Преимущественное накопление жира в периферических отделах печёночной дольки чаще указывает на:', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:25.144374+00', E'2026-10-25 15:51:25.471223+00'),
  (E'3edd286e-256e-407f-8503-45a581a47503', E'theory', E'general', E'1', E'Какой вариант соответствует жировой дистрофии миокарда?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:25.578822+00', E'2026-10-25 15:51:25.913101+00'),
  (E'1598e104-344b-4c98-864d-c980323c9da8', E'theory', E'general', E'1', E'Какова одна из наиболее частых причин жировой дистрофии миокарда?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:26.0201+00', E'2026-10-25 15:51:26.330103+00'),
  (E'5f1aeae5-f81d-4545-b7b3-88d57c32ab2d', E'theory', E'general', E'1', E'Какой исход наиболее характерен для жировой дистрофии печени при отсутствии выраженного некроза?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:26.425996+00', E'2026-10-25 15:51:26.718618+00'),
  (E'1158ed83-d7e2-49c3-8ddf-19e7a8eb9058', E'theory', E'general', E'1', E'При сахарном диабете какое изменение гепатоцитов связано с нарушением углеводного обмена?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:26.824882+00', E'2026-10-25 15:51:27.159868+00'),
  (E'6a34858d-46d6-4feb-a7e1-3074ca386944', E'theory', E'general', E'1', E'Какое изменение почечных канальцев характерно для сахарного диабета?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:27.257965+00', E'2026-10-25 15:51:27.586914+00'),
  (E'9ebc5e2c-4920-40a0-b7d3-ab16e505dfcb', E'theory', E'general', E'1', E'При инфильтрации дистрофическое изменение возникает преимущественно вследствие:', NULL, E'f', E't', NULL, E'2026-10-25 15:52:42.742206+00', E'2026-10-25 15:52:43.231536+00'),
  (E'555a0746-4c91-41e9-8642-c11eb5c4699b', E'theory', E'general', E'6', E'Воспаление — это прежде всего', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:20.301239+00', E'2026-10-25 20:53:20.793006+00'),
  (E'fb5ba8cc-7ed5-4d7c-82d9-39293342cd53', E'theory', E'general', E'2', E'Что относят к стромально-сосудистым диспротеинозам?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:31.051102+00', E'2026-10-29 19:06:31.55661+00'),
  (E'172e481c-e541-42e8-81c3-4c2e6c7254b7', E'theory', E'general', E'4', E'Как образуются клетки сердечных пороков?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:44.544589+00', E'2026-10-25 20:31:44.842822+00'),
  (E'68e51e1b-702e-4588-b7df-772ddb2d464f', E'theory', E'general', E'1', E'Как называется характерное поражение клубочков при диабетической микроангиопатии?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:27.69648+00', E'2026-10-25 15:51:27.999039+00'),
  (E'c260ff7d-b91c-4845-81cd-49ff0a7fb6fd', E'theory', E'general', E'2', E'Каков возможный благоприятный исход мукоидного набухания?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:32.565654+00', E'2026-10-29 19:06:32.883343+00'),
  (E'3c9d35e3-1e71-4e92-912a-def790bf9fb0', E'theory', E'general', E'2', E'Какое утверждение о фибриноидном набухании верно?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:33.800666+00', E'2026-10-29 19:06:34.157239+00'),
  (E'8b9c9ac9-2217-4100-87df-861848f203de', E'theory', E'general', E'1', E'Гликогенозы — это:', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:28.090458+00', E'2026-10-25 15:51:28.422191+00'),
  (E'45c1ee9a-1b90-4c78-ac7c-9a82243126ed', E'theory', E'general', E'2', E'Какой вид гиалина характерен для мелких сосудов при сахарном диабете?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:35.145797+00', E'2026-10-29 19:06:35.470416+00'),
  (E'45f13b67-a42a-4ba9-9cea-bfac1eb5c9cf', E'theory', E'general', E'2', E'Что лежит в основе увеличения массы жировой ткани при ожирении и чем отличаются основные морфологические механизмы этого процесса?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:36.413499+00', E'2026-10-29 19:06:36.759414+00'),
  (E'bbdcdd6f-1b21-4b96-8f12-0cc0a129accd', E'theory', E'general', E'1', E'Какое утверждение о паренхиматозных дистрофиях верно?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:28.511047+00', E'2026-10-25 15:51:28.850432+00'),
  (E'd162be65-291b-44f2-87ab-a37d944272c9', E'theory', E'general', E'2', E'Какой тип ожирения характеризуется увеличением количества обычных по размеру жировых клеток?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:37.791116+00', E'2026-10-29 19:06:38.113721+00'),
  (E'aa1adc4c-56a0-4c22-b615-5f625e96e256', E'theory', E'general', E'2', E'Как классифицируют ожирение по внешнему распределению жировых отложений?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:39.077505+00', E'2026-10-29 19:06:39.410251+00'),
  (E'5e3d92ed-94c4-4e90-86d3-80422112c4ee', E'theory', E'general', E'2', E'Что наиболее характерно для вторичного амилоидоза?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:40.350784+00', E'2026-10-29 19:06:40.6738+00'),
  (E'4fc7082f-3ac6-4f7c-94af-da5c21cfc181', E'theory', E'general', E'1', E'Выберите НЕВЕРНОЕ утверждение о дистрофиях.', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:28.958245+00', E'2026-10-25 15:51:29.293916+00'),
  (E'd273b617-20e6-42fc-b4b1-1a5cd521f3fa', E'theory', E'general', E'2', E'Какие изменения могут наблюдаться в почках при выраженном амилоидозе?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:41.610112+00', E'2026-10-29 19:06:41.931893+00'),
  (E'7323da51-8ddd-4448-aeb6-eaf786a66e64', E'theory', E'general', E'2', E'Что характерно для периколлагенового (мезенхимального) амилоидоза?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:42.866371+00', E'2026-10-29 19:06:43.187781+00'),
  (E'39186242-e6ca-4219-b0ea-9270624810d8', E'theory', E'general', E'1', E'Какое утверждение лучше всего отражает значение паренхиматозных дистрофий?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 15:51:29.383639+00', E'2026-10-25 15:51:29.697536+00'),
  (E'ec18de1f-dc3f-4b2b-b520-77979be02f73', E'theory', E'general', E'2', E'Какой макроскопический признак описан для печени при выраженном амилоидозе?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:44.141493+00', E'2026-10-29 19:06:44.470646+00'),
  (E'cd9dc367-e6cf-4135-8882-6e3c807954a2', E'theory', E'general', E'5', E'Какой тромб типичен для артерий?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:25.693314+00', E'2026-10-29 19:00:26.349396+00'),
  (E'c36acc4d-7f52-4739-913f-ddd3ce0ba647', E'theory', E'general', E'5', E'Какой признак характерен для прижизненного тромба?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:26.88705+00', E'2026-10-29 19:00:27.241764+00'),
  (E'1f31428c-d883-4f63-9cc7-ea80eb2154ec', E'theory', E'general', E'5', E'Пристеночный тромб — это тромб, который', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:27.358949+00', E'2026-10-29 19:00:27.741951+00'),
  (E'fbff107e-827e-4b0a-ba88-706157f62887', E'theory', E'general', E'5', E'Организация тромба с образованием каналов называется', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:28.321835+00', E'2026-10-29 19:00:28.657013+00'),
  (E'f0da8d90-37b8-42b7-a0c3-108bfe574580', E'theory', E'general', E'5', E'Петрификация тромба — это', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:28.758245+00', E'2026-10-29 19:00:29.09601+00'),
  (E'cbb8c66c-c6be-4358-88a2-b0f62786df4a', E'theory', E'general', E'5', E'Чем опасен септический распад тромба?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:29.652205+00', E'2026-10-29 19:00:30.000683+00'),
  (E'f0e50622-bf6b-48fb-9c00-29f8fc4ae035', E'theory', E'general', E'5', E'Эмболия — это', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:30.101307+00', E'2026-10-29 19:00:30.503539+00'),
  (E'b7512588-538c-4fd0-98d5-5b9f2497288c', E'theory', E'general', E'5', E'Ретроградная эмболия возникает, когда эмбол', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:31.031462+00', E'2026-10-29 19:00:31.352625+00'),
  (E'a93c1202-230b-469e-9a1b-d9101ec440a8', E'theory', E'general', E'5', E'Для парадоксальной эмболии необходимо', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:31.45557+00', E'2026-10-29 19:00:31.769312+00'),
  (E'30811497-d642-4191-9e9d-6d128f95330c', E'theory', E'general', E'5', E'Для жировой эмболии характерны', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:32.326261+00', E'2026-10-29 19:00:32.709749+00'),
  (E'fdf7ffca-2171-4586-af41-1032963e99ea', E'theory', E'general', E'5', E'Воздушная эмболия вероятна при', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:32.814773+00', E'2026-10-29 19:00:33.147648+00'),
  (E'a3c12f47-a8ba-4147-883a-29a093272ecb', E'theory', E'general', E'5', E'Микробная эмболия — это', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:33.724652+00', E'2026-10-29 19:00:34.098624+00'),
  (E'b17d1c70-7852-40b0-87e9-9ef244482129', E'theory', E'general', E'5', E'Тканевая эмболия возможна при попадании в кровь', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:34.221888+00', E'2026-10-29 19:00:34.626203+00'),
  (E'dfd5b93f-110b-4888-a7a7-a584e0ec6d6d', E'theory', E'general', E'5', E'Наиболее частый источник ТЭЛА', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:35.177469+00', E'2026-10-29 19:00:35.537631+00'),
  (E'83f49613-45b3-4d3e-a794-06077996abeb', E'theory', E'general', E'5', E'Массивная ТЭЛА может вызвать', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:35.637598+00', E'2026-10-29 19:00:35.9517+00'),
  (E'6614b0e2-6f6c-4f67-abc2-5571a009c41b', E'theory', E'general', E'5', E'Морфологический признак острой массивной ТЭЛА', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:36.525112+00', E'2026-10-29 19:00:36.858642+00'),
  (E'8d34ada7-a9a9-4cfd-a4ae-addebe33a183', E'theory', E'general', E'5', E'Почему мелкая эмболия лёгочной артерии не всегда вызывает инфаркт?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:36.960265+00', E'2026-10-29 19:00:37.292732+00'),
  (E'bdd58325-ea1a-4196-8521-4d5310f3826f', E'theory', E'general', E'5', E'Эмболия почечной артерии может привести к', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:37.850372+00', E'2026-10-29 19:00:38.190448+00'),
  (E'70ee3ec7-7252-44c8-83f9-50a68dbfec7a', E'theory', E'general', E'4', E'Что лежит в основе бурой индурации лёгких?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:44.935467+00', E'2026-10-25 20:31:45.232083+00'),
  (E'47981803-2c1f-4c7d-85b5-44e55dcc0f1c', E'theory', E'general', E'2', E'Какой процесс лежит в основе мукоидного набухания?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:31.66026+00', E'2026-10-29 19:06:32.01902+00'),
  (E'aedee360-0bef-48db-ad80-1e3afaf0d80b', E'theory', E'general', E'2', E'Что характерно для фибриноидного набухания?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:32.972997+00', E'2026-10-29 19:06:33.296011+00'),
  (E'c66cd57a-08b9-4d3c-8680-c8bc4c588b7d', E'theory', E'general', E'4', E'Как выглядит печень при хроническом венозном застое?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:45.322239+00', E'2026-10-25 20:31:45.639411+00'),
  (E'ffa3703e-ad56-47a8-a009-23333aee19fe', E'theory', E'general', E'2', E'Что называют гиалинозом?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:34.261082+00', E'2026-10-29 19:06:34.589264+00'),
  (E'63451ceb-d0f3-44c7-8a13-3fabd5d3ce10', E'theory', E'general', E'4', E'Что часто вызывает хронический венозный застой в большом круге?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:45.730472+00', E'2026-10-25 20:31:46.049911+00'),
  (E'152e3a5d-f0c7-42a3-835c-426a975d8d3f', E'theory', E'general', E'4', E'Как называется скопление транссудата в брюшной полости?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:46.136139+00', E'2026-10-25 20:31:46.605124+00'),
  (E'586542ea-a8c8-4818-b995-40e0d240e3fc', E'theory', E'general', E'2', E'С чем связывают образование простого гиалина в сосудах при гипертонической болезни?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:35.563417+00', E'2026-10-29 19:06:35.899949+00'),
  (E'83c56849-de85-4563-b888-c952b1de33b2', E'theory', E'general', E'4', E'Какое сочетание характерно для портальной гипертензии?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:46.692106+00', E'2026-10-25 20:31:46.985976+00'),
  (E'51a975dd-e561-4780-9af2-217d28bb28db', E'theory', E'general', E'4', E'Какой механизм вызывает застойную спленомегалию?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:47.079109+00', E'2026-10-25 20:31:47.381092+00'),
  (E'd5092a77-c826-4581-8899-360e5bbf2626', E'theory', E'general', E'2', E'Какова первая степень ожирения по превышению возрастной нормы массы тела?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:36.866942+00', E'2026-10-29 19:06:37.254422+00'),
  (E'b86b4260-a9f2-4bbf-8cda-539fb8c9b06f', E'theory', E'general', E'4', E'Что называют кровотечением?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:47.472066+00', E'2026-10-25 20:31:47.767158+00'),
  (E'92abe209-9f93-4c84-859a-fabbe806b728', E'theory', E'general', E'4', E'Какое кровотечение называют аррозивным?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:47.858129+00', E'2026-10-25 20:31:48.159435+00'),
  (E'64cfd88c-db39-439e-b605-f01535eccb5f', E'theory', E'general', E'2', E'Что характерно для гипертрофического типа ожирения?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:38.21506+00', E'2026-10-29 19:06:38.528949+00'),
  (E'bea7dafc-e6d0-4c0e-a96b-f4de443a8be2', E'theory', E'general', E'4', E'Что такое диапедезное кровоизлияние?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:48.249343+00', E'2026-10-25 20:31:48.577013+00'),
  (E'38abef5b-7ab5-46f2-aa82-f77507874d2d', E'theory', E'general', E'4', E'Чем гематома отличается от геморрагической инфильтрации?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:48.667956+00', E'2026-10-25 20:31:48.977054+00'),
  (E'4a319d9b-ea6c-46ae-9065-6e7162069f35', E'theory', E'general', E'2', E'Что такое амилоидоз?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:39.50291+00', E'2026-10-29 19:06:39.833325+00'),
  (E'b895e7df-ec0d-46a9-bec8-d2b29bb7cde2', E'theory', E'general', E'4', E'Как называется скопление крови в плевральной полости?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:49.065976+00', E'2026-10-25 20:31:49.382248+00'),
  (E'925851f3-d499-4182-b127-1574ac09aef0', E'theory', E'general', E'4', E'Что определяет опасность кровоизлияния в головной мозг?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:49.471081+00', E'2026-10-25 20:31:49.770915+00'),
  (E'89889342-995f-4823-9143-8bd42de745b6', E'theory', E'general', E'2', E'Какой белок-предшественник связан с AA-амилоидозом?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:40.770765+00', E'2026-10-29 19:06:41.090058+00'),
  (E'83311761-c9e8-4aa3-b50e-cb559c13d932', E'theory', E'general', E'4', E'Какой исход кровоизлияния возможен при благоприятном течении?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:49.859353+00', E'2026-10-25 20:31:50.224214+00'),
  (E'4b653848-c6fa-4409-ae4e-56dcf7a035a3', E'theory', E'general', E'4', E'Что понимают под геморрагическим диатезом?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:50.316297+00', E'2026-10-25 20:31:50.632365+00'),
  (E'75962d2f-db31-4d5b-9e51-a24ed128161c', E'theory', E'general', E'2', E'Что означает периретикулярный (паренхиматозный) амилоидоз?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:42.032867+00', E'2026-10-29 19:06:42.367723+00'),
  (E'f1cd0bc5-ef2a-49b4-841f-c26a1a55850b', E'theory', E'general', E'2', E'Какие ткани и структуры преимущественно вовлекаются при периколлагеновом амилоидозе?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:43.283686+00', E'2026-10-29 19:06:43.604006+00'),
  (E'd8caa10c-41cd-48e3-9590-76380fe4dd9d', E'theory', E'general', E'2', E'Какие изменения селезенки связаны с отложением амилоида?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:44.565643+00', E'2026-10-29 19:06:44.949941+00'),
  (E'793314de-a33d-4d21-a043-c1e249721257', E'theory', E'general', E'9', E'Какой исход следует обозначить термином «реституция» после повреждения ткани?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:15:50.044509+00', E'2026-10-29 19:15:50.52449+00'),
  (E'c3fef176-1576-45bf-98be-9d21b59b0917', E'theory', E'general', E'5', E'Какой тромб чаще формируется в глубоких венах ног?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:26.43924+00', E'2026-10-29 19:00:26.751421+00'),
  (E'9fde21fe-622f-4576-ba41-a15d02fea248', E'theory', E'general', E'5', E'Где часто образуется тромб после инфаркта миокарда?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:27.865458+00', E'2026-10-29 19:00:28.216344+00'),
  (E'1232583a-c69c-4f00-995d-76343dd4f368', E'theory', E'general', E'5', E'Отрыв части тромба приводит к', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:29.200041+00', E'2026-10-29 19:00:29.543473+00'),
  (E'8335ee21-5584-4b75-b243-20eca12aa1f1', E'theory', E'general', E'5', E'Ортоградная эмболия означает движение эмбола', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:30.597693+00', E'2026-10-29 19:00:30.924816+00');
INSERT INTO public.questions (id, section, block, topic_id, prompt, image_path, is_exam, is_published, created_by, created_at, updated_at) VALUES
  (E'a6012c5b-49a2-4c75-898b-66c4a703bb88', E'theory', E'general', E'5', E'Жировая эмболия после перелома возникает из-за', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:31.887568+00', E'2026-10-29 19:00:32.219568+00'),
  (E'16785903-7360-4449-ad97-0d4638f0ec7a', E'theory', E'general', E'5', E'Газовая эмболия при декомпрессионной болезни связана с', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:33.266768+00', E'2026-10-29 19:00:33.618718+00'),
  (E'1a24345e-a94a-47c1-8dcb-a975babf76d5', E'theory', E'general', E'5', E'Эмболия инородными телами возникает при', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:34.738027+00', E'2026-10-29 19:00:35.066643+00'),
  (E'0b0a2985-7e1d-45b8-bbb4-a37aea86c53d', E'theory', E'general', E'5', E'Острое лёгочное сердце при ТЭЛА — это', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:36.056252+00', E'2026-10-29 19:00:36.422171+00'),
  (E'1f40cfac-ad88-446a-bbd9-1a645e6c8c9a', E'theory', E'general', E'5', E'Тромбоэмболический синдром — это', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:37.392705+00', E'2026-10-29 19:00:37.749686+00'),
  (E'a31d4950-4f04-4bb4-a905-d6694a14cd0d', E'theory', E'general', E'5', E'Ишемия — это', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:38.282943+00', E'2026-10-29 19:00:38.606195+00'),
  (E'd13cd01e-b99d-4587-92bd-e0d916db1b42', E'theory', E'general', E'5', E'Ангиоспастическая ишемия возникает вследствие', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:38.709067+00', E'2026-10-29 19:00:39.270023+00'),
  (E'21b90020-3fe5-4635-992a-ddbb2ba5d124', E'theory', E'general', E'5', E'Закупорка артерии тромбом вызывает тип ишемии', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:39.364758+00', E'2026-10-29 19:00:39.699982+00'),
  (E'03ea3084-15aa-493a-b432-88adb1e38bdb', E'theory', E'general', E'10', E'Какое определение наиболее полно отражает сущность опухоли?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:24.792207+00', E'2026-10-25 22:13:25.12495+00'),
  (E'b5aeaad9-a52f-4c15-a87f-3417d354cfb6', E'theory', E'general', E'4', E'Какое нарушение лежит в основе тромбоцитопенической пурпуры?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:50.723549+00', E'2026-10-25 20:31:51.017177+00'),
  (E'49a2c3cd-c224-4b7f-ba07-70a59919933b', E'theory', E'general', E'6', E'По преобладающему компоненту воспаление традиционно подразделяют на', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:20.909427+00', E'2026-10-25 20:53:21.251601+00'),
  (E'56da18e9-c6d7-4c34-b002-7728425149d5', E'theory', E'general', E'4', E'Что представляет собой ДВС-синдром?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:51.106423+00', E'2026-10-25 20:31:51.413415+00'),
  (E'a31c1e7e-a759-4208-8ec4-40a5c55d0e22', E'theory', E'general', E'2', E'В каких структурах часто развивается мукоидное набухание?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:32.117305+00', E'2026-10-29 19:06:32.474754+00'),
  (E'dcb579d0-f766-4e10-b31d-27058020c329', E'theory', E'general', E'4', E'Какова типичная последовательность патогенеза ДВС-синдрома?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:51.507482+00', E'2026-10-25 20:31:51.812888+00'),
  (E'63c2b95e-58fa-4b11-a0bb-c576e6dd5b90', E'theory', E'general', E'6', E'Как правильно различать классификации воспаления по течению и распространённости?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:21.35043+00', E'2026-10-25 20:53:21.661315+00'),
  (E'32d2d32d-3c72-4fdb-98d0-47d08c71db88', E'theory', E'general', E'4', E'Почему при ДВС-синдроме одновременно возникают тромбозы и кровоточивость?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:51.905885+00', E'2026-10-25 20:31:52.209815+00'),
  (E'771afc28-0cac-41ee-be56-062e09b7064f', E'theory', E'general', E'2', E'Какой вариант может быть исходом фибриноидного набухания?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:33.386341+00', E'2026-10-29 19:06:33.701828+00'),
  (E'9dc686b7-93d0-460c-99f0-251a2bdd8984', E'theory', E'general', E'4', E'Какое изменение может быть проявлением ДВС-синдрома в почках?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:52.298891+00', E'2026-10-25 20:31:52.60627+00'),
  (E'f15f9045-1b8f-4f43-8c42-01b43e1a0c4e', E'theory', E'general', E'6', E'Какой признак наиболее характерен для серозного воспаления?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:21.751068+00', E'2026-10-25 20:53:22.051003+00'),
  (E'0f094078-4297-4209-b19e-5216d4dfa3ed', E'theory', E'general', E'2', E'Какой вариант гиалина типичен для сосудов при гипертонической болезни?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:34.683011+00', E'2026-10-29 19:06:35.050249+00'),
  (E'7afbaf10-962e-4a31-9977-0a4fbac5503e', E'theory', E'general', E'4', E'Что называют шоком в патологоанатомическом понимании?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:52.701198+00', E'2026-10-25 20:31:53.003893+00'),
  (E'5c97f5fb-45fb-4b87-b270-c3811db6360d', E'theory', E'general', E'4', E'Какой вид шока связан с быстрым уменьшением объёма циркулирующей крови?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:53.101199+00', E'2026-10-25 20:31:53.407775+00'),
  (E'08015b62-adc7-4904-b55e-03dac689d054', E'theory', E'general', E'2', E'Для каких состояний характерен сложный гиалин?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:35.993714+00', E'2026-10-29 19:06:36.317836+00'),
  (E'b3d001ad-ee9e-4ab5-9a21-882dd9048d9a', E'theory', E'general', E'6', E'Каковы наиболее вероятные исходы неосложнённого серозного воспаления?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:22.14367+00', E'2026-10-25 20:53:22.449835+00'),
  (E'89269d46-9285-4d40-8231-d4be241346fb', E'theory', E'general', E'4', E'Какой механизм характерен для кардиогенного шока?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:53.498907+00', E'2026-10-25 20:31:53.804733+00'),
  (E'a55c95dd-b473-45df-be46-06afb4a42dc4', E'theory', E'general', E'2', E'Какой диапазон превышения массы тела соответствует третьей степени ожирения?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:37.363556+00', E'2026-10-29 19:06:37.692357+00'),
  (E'2783194f-14d0-4114-a9cf-97524b9ca403', E'theory', E'general', E'4', E'Что лежит в основе септического шока?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:53.893218+00', E'2026-10-25 20:31:54.239548+00'),
  (E'dc70bec6-e9da-45a1-9996-d5c77aefa539', E'theory', E'general', E'6', E'Что лежит в основе фибринозного воспаления?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:22.540014+00', E'2026-10-25 20:53:22.870489+00'),
  (E'239eb57a-f8e8-418e-bd78-5212112f764a', E'theory', E'general', E'4', E'Какое изменение возможно в почках при тяжёлом шоке?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:54.331022+00', E'2026-10-25 20:31:54.632172+00'),
  (E'fcb6bd47-f1dc-4837-b132-5954db0b35a1', E'theory', E'general', E'2', E'Какой тип ожирения считается неблагоприятным?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:38.634722+00', E'2026-10-29 19:06:38.977875+00'),
  (E'cb53035d-d67c-4fbe-a809-d4889c707d51', E'theory', E'general', E'2', E'Какие формы амилоидоза выделяют по происхождению?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:39.926407+00', E'2026-10-29 19:06:40.252093+00'),
  (E'77b2cb71-c0bc-41ea-8308-5803aec7f955', E'theory', E'general', E'2', E'Какой орган особенно часто и выраженно поражается при вторичном амилоидозе?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:41.186666+00', E'2026-10-29 19:06:41.511115+00'),
  (E'011f5e5f-f311-4640-a96a-a504aa502022', E'theory', E'general', E'2', E'Какие органы преимущественно поражаются при периретикулярном амилоидозе?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:42.461668+00', E'2026-10-29 19:06:42.771615+00'),
  (E'6ae38780-25df-4643-a72d-ef663003e47c', E'theory', E'general', E'2', E'Каково основное функциональное последствие выраженного амилоидоза?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:06:43.705564+00', E'2026-10-29 19:06:44.044879+00'),
  (E'63a64097-b754-4c5d-b1d5-5aa03f0a9929', E'theory', E'general', E'9', E'Какой морфологический процесс лежит в основе склероза органа?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:16:07.422213+00', E'2026-10-29 19:16:07.841807+00'),
  (E'2c3f5433-1a22-424d-9968-3fc735e23754', E'theory', E'general', E'4', E'Что называют транссудатом?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:40.452283+00', E'2026-10-25 20:31:40.851714+00'),
  (E'2620d3d9-ec08-44da-bb97-61877b04ddaa', E'theory', E'general', E'4', E'Какой механизм способствует отёку при сердечной недостаточности?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:40.95131+00', E'2026-10-25 20:31:41.256824+00'),
  (E'e7cdeeac-6335-45dc-9248-cb67850b49f3', E'theory', E'general', E'4', E'Какое сочетание характерно для отёка лёгких?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:41.355016+00', E'2026-10-25 20:31:41.662516+00'),
  (E'953e4d0d-a7fa-4da8-a309-c02aa644ab72', E'theory', E'general', E'4', E'Почему отёк головного мозга особенно опасен?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:41.753902+00', E'2026-10-25 20:31:42.093734+00'),
  (E'41c373dc-45d4-4e4e-a016-088646687b7f', E'theory', E'general', E'4', E'Что такое водянка серозной полости?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:42.183566+00', E'2026-10-25 20:31:42.482703+00'),
  (E'6eaa174d-2bbf-4571-989c-8bfb05510380', E'theory', E'general', E'4', E'Как развивается лимфедема?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:42.572479+00', E'2026-10-25 20:31:42.881078+00'),
  (E'ee233422-707a-4595-b724-a40340dba071', E'theory', E'general', E'4', E'Какое последствие может иметь повреждение грудного протока?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:42.967588+00', E'2026-10-25 20:31:43.271392+00'),
  (E'f2ef5a6a-09b9-4764-8847-82e2d6912f2d', E'theory', E'general', E'4', E'Чем артериальная гиперемия отличается от венозного полнокровия?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:43.359803+00', E'2026-10-25 20:31:43.649656+00'),
  (E'352bbc63-379f-4fe3-9bbf-45b2cedcde5d', E'theory', E'general', E'4', E'Как выглядит ткань при остром венозном застое?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:31:43.736711+00', E'2026-10-25 20:31:44.049116+00'),
  (E'bcca9260-ca21-4f9c-812b-e1448e24e8f4', E'theory', E'general', E'6', E'Какой морфологический признак отличает крупозное воспаление?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:22.963992+00', E'2026-10-25 20:53:23.26797+00'),
  (E'a335d01f-6158-41fa-8bcc-8542022a7f67', E'theory', E'general', E'6', E'Какой признак наиболее характерен для дифтеритического воспаления?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:23.354481+00', E'2026-10-25 20:53:23.685994+00'),
  (E'f4779588-681d-4830-b8ef-07c9de1b6acc', E'theory', E'general', E'9', E'Какое определение наиболее точно отражает регенерацию в патологической анатомии?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:15:47.827665+00', E'2026-10-29 19:15:48.291545+00'),
  (E'0464d2a6-d87d-46d0-b353-8f587bfd5c0b', E'theory', E'general', E'6', E'Какой фактор в значительной степени определяет крупозный или дифтеритический характер фибринозного воспаления?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:23.777375+00', E'2026-10-25 20:53:24.085049+00'),
  (E'afd63cf0-739c-4dc5-b074-27e5b41d2432', E'theory', E'general', E'6', E'Какое осложнение особенно опасно при фибринозном воспалении слизистой гортани?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:24.173007+00', E'2026-10-25 20:53:24.501414+00'),
  (E'1a508106-420a-434a-8683-5f8b7a625e87', E'theory', E'general', E'9', E'При поверхностном повреждении эпителия какие условия наиболее благоприятствуют восстановлению исходной структуры без грубого рубца?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:15:49.480497+00', E'2026-10-29 19:15:49.930716+00'),
  (E'1b9eaa13-f44b-4a4a-bf57-a91baf136802', E'theory', E'general', E'9', E'Какое сочетание морфологических признаков отличает грануляционную ткань от зрелого рубца?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:15:51.219218+00', E'2026-10-29 19:15:51.68148+00'),
  (E'68512e93-cfbb-42f4-93ef-355d3250fe31', E'theory', E'general', E'6', E'Абсцесс — это', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:24.999777+00', E'2026-10-25 20:53:25.31308+00'),
  (E'b53ea179-72c8-4a18-8809-ac8c76d1bdc5', E'theory', E'general', E'9', E'Небольшая чистая хирургическая рана с хорошо сопоставленными краями заживает быстрее преимущественно потому, что при первичном натяжении', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:15:51.810252+00', E'2026-10-29 19:15:52.228954+00'),
  (E'4466e06d-b1db-47c5-9017-74843df0e75d', E'theory', E'general', E'9', E'Хроническая язва длительно не закрывается, несмотря на начавшуюся репаративную реакцию. Какой вариант патологической регенерации описан?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:15:53.469465+00', E'2026-10-29 19:15:54.056196+00'),
  (E'27f32b95-9f86-4224-8f08-418a91ab027c', E'theory', E'general', E'9', E'В хронически раздражаемом эпителии один зрелый тип эпителия замещается другим. Как правильно классифицировать такое изменение?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:15:54.170331+00', E'2026-10-29 19:15:54.59954+00'),
  (E'19f9c29d-e4f1-4d60-bcdd-af40256b9c70', E'theory', E'general', E'9', E'Как поддерживается нормальное обновление эпидермиса при сохранной структуре базального слоя?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:15:54.740999+00', E'2026-10-29 19:15:55.226476+00'),
  (E'839c2da0-09bd-49aa-8000-1fdb24de5e23', E'theory', E'general', E'9', E'Какое определение наиболее полно описывает адаптацию клеток, тканей и органов?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:15:56.034395+00', E'2026-10-29 19:15:56.497376+00'),
  (E'4d03a4e1-62b0-44fd-a3fe-25fb7b177a05', E'theory', E'general', E'9', E'Как точнее определить компенсацию в системе адаптивных реакций?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:15:56.629514+00', E'2026-10-29 19:15:57.096499+00'),
  (E'89d6b4c9-5043-4767-bf6b-b6602bb07633', E'theory', E'general', E'9', E'Какой пример соответствует рабочей гипертрофии, обусловленной повышенной нагрузкой на орган?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:15:57.858272+00', E'2026-10-29 19:15:58.332162+00'),
  (E'd43715e8-5716-4dfd-a196-a4c7876ec262', E'theory', E'general', E'9', E'При оценке увеличенного органа какое морфологическое отличие указывает на истинную, а не ложную гипертрофию?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:15:58.467894+00', E'2026-10-29 19:15:58.938391+00'),
  (E'67be22ef-0f96-428b-8de0-a56cd8fba379', E'theory', E'general', E'9', E'После нефрэктомии одной почки оставшаяся почка увеличивается и принимает на себя большую часть функции. Как называется это изменение?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:15:59.043796+00', E'2026-10-29 19:15:59.552106+00'),
  (E'ecc68018-f8e3-4171-a1f5-54b319ce6977', E'theory', E'general', E'9', E'После повреждения периферического нерва мышца теряет нервную стимуляцию, её волокна истончаются, сила снижается. Какой механизм лежит в основе изменений?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:15:59.689976+00', E'2026-10-29 19:16:00.17574+00'),
  (E'539f5835-809c-485d-9ddb-6116fa03db6c', E'theory', E'general', E'9', E'Какой причинный фактор позволяет отнести атрофию ткани к дисгормональной?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:16:00.297393+00', E'2026-10-29 19:16:00.721433+00'),
  (E'f5c1c0f0-5743-42e2-98c3-2fde2c8d6496', E'theory', E'general', E'9', E'У пациента с выраженным стенозом почечной артерии почка постепенно уменьшается в размерах. Какой вид атрофии соответствует ведущему механизму?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:16:01.372961+00', E'2026-10-29 19:16:01.7762+00'),
  (E'fc128093-69fb-4c93-b3ac-e67e9706a15f', E'theory', E'general', E'9', E'Какой признак позволяет отличить компрессионную атрофию от дисфункциональной?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:16:01.895533+00', E'2026-10-29 19:16:02.323725+00'),
  (E'd0f34ea9-a8c8-4599-ab5d-d494568404b5', E'theory', E'general', E'9', E'Какие клетки непосредственно обеспечивают синтез коллагена и сокращение формирующегося рубца?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:16:03.036657+00', E'2026-10-29 19:16:03.451235+00'),
  (E'ea709fa7-9879-47f9-8f9c-976ca0f854cc', E'theory', E'general', E'9', E'Небольшой дефект эпителия заживает при сохранных резервных клетках и базальной мембране. Какой исход наиболее вероятен?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:16:03.591294+00', E'2026-10-29 19:16:04.003367+00'),
  (E'408ca301-b7a8-4727-a78e-b45922956989', E'theory', E'general', E'9', E'В биопсии эндометрия выявлено увеличение числа железистых клеток при их пролиферации. Какой адаптивный процесс описан?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:16:04.777094+00', E'2026-10-29 19:16:05.178841+00'),
  (E'b091caad-50c8-43ff-a3f5-66e9424f40c7', E'theory', E'general', E'9', E'Мышца увеличена в объёме, однако функциональные волокна истончены, а между ними накоплены жир и соединительная ткань. Как классифицировать изменение?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:16:05.292023+00', E'2026-10-29 19:16:05.714711+00'),
  (E'a78d3f32-3fcd-45fa-a57d-a0c93e2cdffe', E'theory', E'general', E'6', E'Гнойный экссудат обычно содержит преимущественно', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:24.609404+00', E'2026-10-25 20:53:24.909818+00'),
  (E'7798d804-4674-4970-90d4-e7fc57a05aac', E'theory', E'general', E'10', E'Какие два компонента обычно различают в микроскопическом строении опухоли?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:25.231353+00', E'2026-10-25 22:13:25.573031+00'),
  (E'27b610f6-dc90-4721-83f5-d6c6cb2d8762', E'theory', E'general', E'3', E'Что понимают под смешанными дистрофиями?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:18.927694+00', E'2026-10-29 18:04:19.427963+00'),
  (E'2615f825-dd7d-4880-b44f-fbee35607643', E'theory', E'general', E'10', E'Почему опухоли называют органоидными или гистиоидными?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:25.664572+00', E'2026-10-25 22:13:25.993772+00'),
  (E'e02e7800-5760-44b2-a0dd-19dd7489dae0', E'theory', E'general', E'5', E'Тромбоз — это', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:23.767469+00', E'2026-10-29 19:00:24.201901+00'),
  (E'00668165-ca4e-4cb4-9df9-5a0f9fc8cdc8', E'theory', E'general', E'10', E'Какой пример лучше всего иллюстрирует тканевый атипизм?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:26.094108+00', E'2026-10-25 22:13:26.459737+00'),
  (E'9c76ce0a-c256-4093-a552-66572aac4663', E'theory', E'general', E'10', E'Какой набор признаков относится к клеточному атипизму опухоли?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:26.557069+00', E'2026-10-25 22:13:26.876138+00'),
  (E'c7a7cb27-38d6-45a3-8650-52dfa395a233', E'macro', E'specific', E'12', E'Определите патологический процесс по макропрепарату.', E'360:storage:5d0e5d32-e2ac-4717-a802-fea5d41bae26', E't', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-11-21 22:43:25.384869+00', E'2026-11-21 22:43:25.833986+00'),
  (E'f2d7a41e-4b03-4365-a83c-2989dd487039', E'theory', E'general', E'43', E'Какие признаки особенно важны при разграничении лейомиомы и лейомиосаркомы?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:46.037444+00', E'2026-10-25 22:14:46.355445+00'),
  (E'78c03a9f-670a-4b31-8cde-2bcc41045a48', E'theory', E'general', E'6', E'Флегмона отличается от абсцесса тем, что при флегмоне', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:25.625691+00', E'2026-10-25 20:53:25.95218+00'),
  (E'741265a2-7c88-4506-8106-25bfcac5d33e', E'theory', E'general', E'6', E'Эмпиема — это', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:26.040831+00', E'2026-10-25 20:53:26.350233+00'),
  (E'1d25fced-af0f-428d-a084-bf47ed8b91c2', E'theory', E'general', E'6', E'Какой исход наиболее характерен для небольшого абсцесса при эффективном дренировании и устранении причины?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:26.434223+00', E'2026-10-25 20:53:26.740323+00'),
  (E'013eee9b-17b8-4d73-98cd-1780499ae56c', E'theory', E'general', E'6', E'Какой морфологический признак характерен для катарального воспаления?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:26.832906+00', E'2026-10-25 20:53:27.138896+00'),
  (E'f2cbee0f-d3eb-4890-b2ab-36fe49c8140f', E'theory', E'general', E'6', E'Какие изменения эпителия часто сопровождают катаральное воспаление?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:27.234736+00', E'2026-10-25 20:53:27.542513+00'),
  (E'3eb828c7-d9c4-42c3-b86e-1547fbaccc05', E'theory', E'general', E'6', E'Геморрагическое воспаление характеризуется', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:27.633487+00', E'2026-10-25 20:53:27.934822+00'),
  (E'1ff307ce-fbe2-4426-80f2-371ae44e3ca2', E'theory', E'general', E'6', E'Какой механизм наиболее непосредственно приводит к образованию экссудата при остром воспалении?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:28.02114+00', E'2026-10-25 20:53:28.378613+00'),
  (E'5d8115ad-6144-4a56-8854-aa8d1e23fcdd', E'theory', E'general', E'6', E'Какой процесс наиболее вероятен при язвенно-некротическом исходе острого воспаления слизистой?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:28.46434+00', E'2026-10-25 20:53:28.757044+00'),
  (E'71626e9a-92ed-41e0-902d-b4b945f6ba36', E'theory', E'general', E'6', E'Когда после острого воспаления вероятнее всего формируется рубец?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:28.842836+00', E'2026-10-25 20:53:29.156834+00'),
  (E'825dd8f7-77c4-48fd-804b-2aa359f0bf0a', E'theory', E'general', E'6', E'Что означает полное разрешение острого воспаления?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:29.241693+00', E'2026-10-25 20:53:29.54444+00'),
  (E'f93361b3-00db-41fc-b91a-d591bb23ec85', E'theory', E'general', E'6', E'Какой фактор способствует переходу острого воспаления в хроническое?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:29.639337+00', E'2026-10-25 20:53:29.933815+00'),
  (E'5ffe055d-64ea-485c-a103-c7edd230a219', E'theory', E'general', E'6', E'Что происходит при организации воспалительного экссудата?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:30.018455+00', E'2026-10-25 20:53:30.318381+00'),
  (E'bc6b97d3-8040-4dbd-94e2-698280416a42', E'theory', E'general', E'6', E'Какой клеточный компонент обычно преобладает в очаге типичного острого гнойного воспаления?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:30.405421+00', E'2026-10-25 20:53:30.703765+00'),
  (E'9f0821d4-dd6a-4e7d-9493-4f3da6aac63e', E'theory', E'general', E'6', E'Какой вариант наиболее точно описывает воспаление серозных оболочек при фибринозном плеврите?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:30.794947+00', E'2026-10-25 20:53:31.092892+00'),
  (E'4160d486-8c72-44d9-b0ac-31b325160c1b', E'theory', E'general', E'6', E'Какой признак позволяет отличить экссудат от транссудата?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:31.182079+00', E'2026-10-25 20:53:31.491052+00'),
  (E'1258eabd-4aad-4766-85b4-73c7947f1f46', E'theory', E'general', E'6', E'Какое утверждение об остром воспалении у детей наиболее корректно?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:31.578353+00', E'2026-10-25 20:53:31.865909+00'),
  (E'6f7fc23f-827f-4160-9f4a-46f43f3e4318', E'theory', E'general', E'6', E'Почему у маленьких детей некоторые острые инфекции могут быстро приобретать распространённый характер?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:31.953809+00', E'2026-10-25 20:53:32.251703+00'),
  (E'd1e8c900-e317-4601-a6b0-552e75e5f069', E'theory', E'general', E'6', E'Какое последствие может возникнуть после фибринозного воспаления брюшины при организации экссудата?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:32.3412+00', E'2026-10-25 20:53:32.650775+00'),
  (E'7b28ac3e-70b8-4f5e-83b8-74f16b7c8f01', E'theory', E'general', E'6', E'Какой вариант наиболее точно описывает роль макрофагов при разрешении острого воспаления?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:32.738711+00', E'2026-10-25 20:53:33.042537+00'),
  (E'd14771f9-7927-4fc6-89ae-6a8ed6d09cf9', E'theory', E'general', E'6', E'Какой исход наиболее вероятен при поверхностном катаральном воспалении слизистой после устранения раздражителя?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:33.128519+00', E'2026-10-25 20:53:33.421131+00'),
  (E'6ed6c634-83a1-4f01-8b79-1bad5440dc72', E'theory', E'general', E'6', E'Какой признак говорит о том, что острое воспаление сопровождается значительным тканевым повреждением?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:33.509097+00', E'2026-10-25 20:53:33.810028+00'),
  (E'88abbdfc-722d-41dc-a1ad-251e2befdec8', E'theory', E'general', E'6', E'Что определяет выбор между полным восстановлением и фиброзным замещением после острого воспаления?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:33.897964+00', E'2026-10-25 20:53:34.213088+00');
INSERT INTO public.questions (id, section, block, topic_id, prompt, image_path, is_exam, is_published, created_by, created_at, updated_at) VALUES
  (E'19f9b670-955f-4ee1-bfeb-d652d59d202e', E'theory', E'general', E'6', E'Какой вариант верно связывает морфологическую форму воспаления и её определяющий экссудат?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:53:34.299202+00', E'2026-10-25 20:53:34.690201+00'),
  (E'e25cba46-6d7b-43a7-af0f-3f36ab917dff', E'theory', E'general', E'7', E'Какой признак наиболее точно определяет пролиферативное (продуктивное) воспаление?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:37.550348+00', E'2026-10-25 20:58:37.895488+00'),
  (E'c61c1f78-51a7-4c01-aae5-1ca0228c7f65', E'theory', E'general', E'7', E'Какая классификация продуктивного воспаления соответствует классическому морфологическому делению?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:37.995341+00', E'2026-10-25 20:58:38.352618+00'),
  (E'16c310d9-26b4-4f84-a9a8-3b036f6d2272', E'theory', E'general', E'7', E'В миокарде выявлены лимфоциты, макрофаги, плазматические клетки, единичные нейтрофилы и фибробласты; кардиомиоциты местами повреждены, между ними формируются коллагеновые волокна. Какой исход наиболее вероятен?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:38.439681+00', E'2026-10-25 20:58:39.025518+00'),
  (E'9a6a8fa5-1bbf-457b-99a8-09f20054f792', E'theory', E'general', E'7', E'Что является ключевым условием формирования гранулемы при гранулематозном воспалении?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:39.11808+00', E'2026-10-25 20:58:39.418008+00'),
  (E'f2e397a6-7c91-4cac-93a2-657b6067c283', E'theory', E'general', E'8', E'Какое соответствие между механизмом и типом гиперчувствительности является правильным?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:32.895372+00', E'2026-10-25 21:07:33.18694+00'),
  (E'4b9d6f7d-0399-4514-9fbd-98f1a042f6a2', E'theory', E'general', E'7', E'При микроскопии гранулемы обнаружен центральный участок казеозного некроза, окруженный эпителиоидными клетками и многоядерными клетками Пирогова—Лангханса, а снаружи — лимфоцитарный вал. Какое заключение наиболее обосновано?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:39.51016+00', E'2026-10-25 20:58:39.815981+00'),
  (E'a65e0736-1c1a-45ac-afb9-ce920b2ae6d0', E'theory', E'general', E'7', E'Какой клеточный компонент наиболее характерен для гранулемы как морфологической структуры?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:39.909393+00', E'2026-10-25 20:58:40.221132+00'),
  (E'2666195e-8025-44ad-9f5d-ec042bd6e6da', E'theory', E'general', E'7', E'Какой признак лучше всего отличает интерстициальное воспаление паренхиматозного органа от преимущественно паренхиматозного повреждения?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:40.313171+00', E'2026-10-25 20:58:40.613456+00'),
  (E'099a5601-3d2f-45e2-bfbc-c2049ab4b1bd', E'theory', E'general', E'7', E'В ткани печени при длительном воспалении выявлены лимфоцитарно-макрофагальный инфильтрат в портальных трактах, разрастание коллагена и постепенное нарушение архитектоники органа. Какой общий механизм объясняет формирование фиброза?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:40.706907+00', E'2026-10-25 20:58:41.015115+00'),
  (E'cbebfd8a-b4f9-4dfd-a47d-f2e268e0190d', E'theory', E'general', E'7', E'Какой морфологический признак наиболее характерен для гуммы при третичном сифилисе?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:41.105111+00', E'2026-10-25 20:58:41.407454+00'),
  (E'05dffe5d-e133-4a28-af1a-573bd894720f', E'theory', E'general', E'7', E'При какой форме лепры наиболее характерны крупные вакуолизированные макрофаги — клетки Вирхова, содержащие многочисленные микобактерии?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:41.500882+00', E'2026-10-25 20:58:41.810284+00'),
  (E'9bf79719-2d94-49ef-bc48-fb44beb7440c', E'theory', E'general', E'7', E'Какой набор признаков наиболее типичен для гранулемы при саркоидозе?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:41.902696+00', E'2026-10-25 20:58:42.204037+00'),
  (E'eadc289f-e846-4a79-8ebe-e197eefd7b29', E'theory', E'general', E'7', E'Какой механизм наиболее непосредственно объясняет появление многоядерных гигантских клеток в гранулеме?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:42.298729+00', E'2026-10-25 20:58:42.599541+00'),
  (E'0fd22f99-1b3f-45fd-b8ff-bc05d2622188', E'theory', E'general', E'7', E'Какое сочетание наиболее точно описывает морфологический исход туберкулезной гранулемы?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:42.692304+00', E'2026-10-25 20:58:43.007042+00'),
  (E'f045e6fa-9792-40f5-abdf-26bb4405cbb9', E'theory', E'general', E'7', E'Чем гуммозный инфильтрат при сифилитическом мезаортите принципиально отличается от типичной гуммы?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:43.105955+00', E'2026-10-25 20:58:43.42336+00'),
  (E'7b60a693-69f5-461f-be5e-b615fe33d561', E'theory', E'general', E'7', E'Какой патогенетический механизм связывает сифилитический мезаортит с мешковидной аневризмой аорты?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:43.532383+00', E'2026-10-25 20:58:43.833496+00'),
  (E'228ce249-6204-4198-83f9-ba0129fb7ce1', E'theory', E'general', E'7', E'Какой вариант наиболее корректно сопоставляет инфекционные и неинфекционные гранулемы?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:43.924864+00', E'2026-10-25 20:58:44.235837+00'),
  (E'91c3c3bd-0145-4bd4-8003-845117226c23', E'theory', E'general', E'7', E'Какой признак позволяет отнести гранулему к гранулеме инородного тела?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:44.332339+00', E'2026-10-25 20:58:44.642062+00'),
  (E'c8eb457e-1335-45c3-9f61-3700a5d7d428', E'theory', E'general', E'7', E'Что наиболее обоснованно подразумевают под гранулематозными заболеваниями?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:44.736535+00', E'2026-10-25 20:58:45.050512+00'),
  (E'138785f1-be5d-4279-b935-600feffc8e1c', E'theory', E'general', E'7', E'В гранулеме обнаружены эпителиоидные клетки и гигантские клетки, но возбудитель при стандартных окрасках не выявлен. Какой вывод наиболее корректен?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:45.140344+00', E'2026-10-25 20:58:45.467248+00'),
  (E'8ff709ac-489b-4d05-8649-a73820088931', E'theory', E'general', E'7', E'Какой морфологический комплекс наиболее характерен для склеромной гранулемы согласно классическому описанию?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:45.558323+00', E'2026-10-25 20:58:45.863187+00'),
  (E'1b29b77c-a2eb-4b6a-85ed-25a9d8b91b00', E'theory', E'general', E'7', E'Какой вариант правильно описывает морфологический спектр гранулем при лепре?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:45.95617+00', E'2026-10-25 20:58:46.249575+00'),
  (E'8c20b8b8-8cbd-4eff-bef2-b202bbf80ade', E'theory', E'general', E'7', E'Какое утверждение наиболее точно отражает значение клеточного иммунного ответа при гранулематозном воспалении?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:46.342106+00', E'2026-10-25 20:58:46.649741+00'),
  (E'3b91eca2-7afe-455a-b986-8321b024b840', E'theory', E'general', E'7', E'Какой исход наиболее вероятен при длительном интерстициальном воспалении, сопровождающемся постоянным повреждением паренхимы и активацией фибробластов?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:46.738821+00', E'2026-10-25 20:58:47.040916+00'),
  (E'65ff643f-a213-4eb0-9fa8-a8ba8497d773', E'theory', E'general', E'7', E'Как следует интерпретировать сочетание хронического воспалительного инфильтрата, разрушения ткани и выраженного фиброза?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:47.133993+00', E'2026-10-25 20:58:47.442697+00'),
  (E'7392f23e-6e96-48b8-b3e7-3cb7e8e67109', E'theory', E'general', E'7', E'Какой морфологический механизм лежит в основе образования воспалительного гиперпластического полипа слизистой оболочки?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:47.536667+00', E'2026-10-25 20:58:47.83296+00'),
  (E'd1d8cc58-58b8-4d4b-bd95-a1298bd1dc5c', E'theory', E'general', E'7', E'Какое сочетание наиболее характерно для остроконечных кондилом в контексте продуктивного воспаления?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:47.921724+00', E'2026-10-25 20:58:48.240532+00'),
  (E'870e41a6-72e6-46aa-824f-56a2f28844df', E'theory', E'general', E'7', E'Какой фактор определяет склонность хронического воспаления к длительному течению и повторным обострениям?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:48.338603+00', E'2026-10-25 20:58:48.63999+00'),
  (E'aa662832-6cea-4642-9fbb-a210f1a00a89', E'theory', E'general', E'5', E'Триада Вирхова включает', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:24.303684+00', E'2026-10-29 19:00:24.704119+00'),
  (E'b55eef05-278f-47bb-9818-d2e43154650c', E'theory', E'general', E'7', E'В биоптате длительно воспаленной слизистой видны полиповидное разрастание, расширенные сосуды, хронический клеточный инфильтрат и фиброз стромы. Как лучше классифицировать процесс?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:48.734041+00', E'2026-10-25 20:58:49.03472+00'),
  (E'9e221404-79da-4301-aff8-a9c1a4fe5a4a', E'theory', E'general', E'7', E'Какой признак помогает отличить гранулему от обычного диффузного хронического воспалительного инфильтрата?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:49.128659+00', E'2026-10-25 20:58:49.429787+00'),
  (E'e02b53cd-28ea-4089-94a7-020741b84974', E'theory', E'general', E'10', E'Как правильнее отличать экспансивный рост опухоли от инфильтрирующего?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:26.966753+00', E'2026-10-25 22:13:27.29162+00'),
  (E'aea35f40-df09-464f-87b3-53054d544739', E'theory', E'general', E'7', E'При оценке гранулемы важно различать этиологию и морфологический тип реакции. Какой вывод из этого принципа наиболее верен?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:49.572255+00', E'2026-10-25 20:58:49.912182+00'),
  (E'741d8e96-df45-481b-b9d3-325f94b2bc42', E'theory', E'general', E'7', E'Какое изменение наиболее вероятно при прогрессирующем склерозе после продуктивного воспаления в органе с ограниченной регенерацией паренхимы?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:50.006104+00', E'2026-10-25 20:58:50.312115+00'),
  (E'bed3b3d8-428d-4ac2-914b-fa8c37cf3f39', E'theory', E'general', E'7', E'Какой вариант наиболее точно описывает возможный исход гранулематозного воспаления при длительном сохранении раздражителя?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:50.401662+00', E'2026-10-25 20:58:50.723348+00'),
  (E'b64549c8-77a0-42fe-bb0a-302d34910c04', E'theory', E'general', E'7', E'Какой признак наиболее характерен для хронического воспаления в сравнении с типичным острым воспалением?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:50.816304+00', E'2026-10-25 20:58:51.113767+00'),
  (E'bf35b774-f86c-45f7-8fdb-a4f73f53ec32', E'theory', E'general', E'10', E'Опухоль выступает в просвет полого органа на ножке, а её основание не прорастает глубоко в стенку. Какой тип роста наиболее вероятен?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:27.387033+00', E'2026-10-25 22:13:27.706274+00'),
  (E'64ec5c12-f0ed-453d-949d-d5d0c8aef162', E'theory', E'general', E'10', E'Какое утверждение наиболее точно характеризует доброкачественную опухоль?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:27.80551+00', E'2026-10-25 22:13:28.112217+00'),
  (E'7e04afcf-11c4-4fce-a076-f0e6c38903dc', E'macro', E'specific', E'12', E'Определите патологический процесс по макропрепарату.', E'360:storage:46c6dda2-ea5e-4540-a329-3e2e1ec88ad3', E't', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-11-21 22:50:33.456955+00', E'2026-11-21 22:50:33.800569+00'),
  (E'b8304fd1-d0eb-42ca-8c10-cce840f693b7', E'theory', E'general', E'10', E'Какой признак наиболее весомо указывает на злокачественное поведение опухоли?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:28.202035+00', E'2026-10-25 22:13:28.506494+00'),
  (E'db15c315-a26a-4e09-9fa6-8ae864be9d7c', E'theory', E'general', E'10', E'Какой вариант правильно описывает основные пути метастазирования?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:28.600358+00', E'2026-10-25 22:13:28.911077+00'),
  (E'5803f405-bebb-4140-8a87-eedd26183633', E'theory', E'general', E'10', E'Что называется рецидивом опухоли?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:29.006202+00', E'2026-10-25 22:13:29.312508+00'),
  (E'c25f43b6-2cf9-47a7-ad9f-6ed1a987ffe9', E'theory', E'general', E'10', E'Какой комплекс наиболее характерен для раковой кахексии?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:29.403993+00', E'2026-10-25 22:13:29.714267+00'),
  (E'20b600f1-adfb-4f62-8402-cf8f981002fc', E'theory', E'general', E'10', E'Какой пример лучше всего соответствует паранеопластическому синдрому?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:29.809867+00', E'2026-10-25 22:13:30.142839+00'),
  (E'177cd05a-c585-4580-9af3-709a3c261183', E'theory', E'general', E'10', E'Какая последовательность наиболее точно отражает типичную схему морфогенеза опухоли?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:30.232997+00', E'2026-10-25 22:13:30.552124+00'),
  (E'e2947111-bb70-4bfd-8191-adc3ec628c13', E'theory', E'general', E'10', E'Что понимают под гистогенезом опухоли?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:30.645083+00', E'2026-10-25 22:13:30.957076+00'),
  (E'8777347a-f13f-480f-9a01-7692b6304a50', E'theory', E'general', E'10', E'Какой перечень соответствует семи классическим гистогенетическим группам опухолей?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:31.046155+00', E'2026-10-25 22:13:31.35589+00'),
  (E'00d9f5a1-09e2-498c-b2af-70008e6015a7', E'theory', E'general', E'10', E'Какая опухоль относится к органонеспецифическим эпителиальным опухолям?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:31.446109+00', E'2026-10-25 22:13:31.765696+00'),
  (E'8e2c9f36-0991-403f-81de-44e66b77686c', E'theory', E'general', E'10', E'Какое строение наиболее характерно для доброкачественной папилломы?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:31.856074+00', E'2026-10-25 22:13:32.175743+00'),
  (E'654b5e7e-1813-4329-ae25-b5d5ab6c785f', E'theory', E'general', E'10', E'Какой признак типичен для аденомы?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:32.265552+00', E'2026-10-25 22:13:32.582189+00'),
  (E'1c6c9423-df6d-438f-8b53-86535a05a7b2', E'theory', E'general', E'10', E'Что отличает carcinoma in situ от инвазивного рака?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:32.668127+00', E'2026-10-25 22:13:32.986304+00'),
  (E'2f9bf124-fa86-4041-a9a6-48429f509b45', E'theory', E'general', E'10', E'Какой микроскопический признак наиболее характерен для ороговевающего плоскоклеточного рака?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:33.074191+00', E'2026-10-25 22:13:33.38652+00'),
  (E'96a6a6a2-568c-4a8e-8c0c-c6f34a01de3a', E'theory', E'general', E'10', E'Чем аденокарцинома принципиально отличается от аденомы?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:33.486799+00', E'2026-10-25 22:13:33.793219+00'),
  (E'b3b535e2-703f-4cda-89aa-df61c0e4d002', E'theory', E'general', E'10', E'Какой вариант лучше всего описывает слизистый (коллоидный) рак?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:33.877544+00', E'2026-10-25 22:13:34.185888+00'),
  (E'b0c60c58-9090-45ca-9189-c9f2c0f2e5b3', E'theory', E'general', E'43', E'Какой признак объединяет мезенхимальные опухоли?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:42.69771+00', E'2026-10-25 22:14:43.044522+00'),
  (E'989881d1-adf1-4fe4-a170-012d65c863c6', E'theory', E'general', E'43', E'Как называется доброкачественная опухоль поперечнополосатой мышечной ткани?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:46.448433+00', E'2026-10-25 22:14:46.768466+00'),
  (E'e0e2df27-1006-4fbf-9612-7eed44406cc9', E'theory', E'general', E'7', E'В очаге хронического воспаления обнаружены плазматические клетки, лимфоциты и макрофаги. Какое утверждение о значении такого состава наиболее корректно?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:51.211514+00', E'2026-10-25 20:58:51.517922+00'),
  (E'ab162df1-ee44-4b42-8aea-6e6d44910483', E'theory', E'general', E'7', E'Какое описание наиболее корректно для специфической гранулемы в патологоанатомическом смысле?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 20:58:51.610697+00', E'2026-10-25 20:58:51.912205+00'),
  (E'82e309e4-d659-443e-8e16-21b05a6fbc4f', E'theory', E'general', E'43', E'Что наиболее характерно для злокачественной мезенхимальной опухоли?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:43.58856+00', E'2026-10-25 22:14:43.908539+00'),
  (E'0bc4f8d3-2b3d-461b-a7e1-56ae29b80178', E'theory', E'general', E'8', E'Какой механизм наиболее характерен для системной анафилаксии при повторном контакте с аллергеном у сенсибилизированного человека?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:23.490546+00', E'2026-10-25 21:07:24.002293+00'),
  (E'a01737a6-4d53-476c-ba23-a93aaae84858', E'theory', E'general', E'8', E'Какое повреждение наиболее типично для гиперчувствительности II типа?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:24.091187+00', E'2026-10-25 21:07:24.393473+00'),
  (E'52be8585-241b-4165-8ea8-3e16335a0c10', E'theory', E'general', E'8', E'При какой реакции гиперчувствительности ведущую роль играют циркулирующие комплексы антиген–антитело, оседающие в сосудистых стенках и клубочках?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:24.485902+00', E'2026-10-25 21:07:24.941509+00'),
  (E'1ce8fc2a-7745-4c4b-974a-fb9e81fb5893', E'theory', E'general', E'8', E'Какой клеточный механизм лежит в основе реакции гиперчувствительности замедленного типа при туберкулиновой пробе?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:25.03959+00', E'2026-10-25 21:07:25.341386+00'),
  (E'69a7a24b-070a-416b-abfe-952e36e33f71', E'theory', E'general', E'8', E'В биоптате кожи через 48 часов после аппликации контактного аллергена обнаружена периваскулярная лимфоцитарная инфильтрация с эпидермальным спонгиозом. Какой механизм наиболее вероятен?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:25.433769+00', E'2026-10-25 21:07:25.744449+00'),
  (E'3fdc5a7c-e9c0-4c56-b299-de0461865d06', E'theory', E'general', E'8', E'Какой механизм наиболее важен при болезни Грейвса, если антитела стимулируют рецептор ТТГ?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:25.829696+00', E'2026-10-25 21:07:26.13318+00'),
  (E'dfd0c48c-f29b-468a-91ca-87bc9c3ab8e7', E'theory', E'general', E'8', E'Какое звено наиболее существенно в патогенезе тиреоидита Хашимото?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:26.219896+00', E'2026-10-25 21:07:26.508233+00'),
  (E'389dc2c8-4d2e-4ca9-896c-3d5f7bc12d13', E'theory', E'general', E'8', E'Какое сочетание наиболее характерно для системной красной волчанки (СКВ)?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:26.596686+00', E'2026-10-25 21:07:26.894958+00'),
  (E'33571c6e-ea78-420a-9ecc-92cee3c4a304', E'theory', E'general', E'8', E'Какой морфологический признак наиболее характерен для синдрома Гудпасчера?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:26.984083+00', E'2026-10-25 21:07:27.279225+00'),
  (E'2e1ca21e-e9b0-48f0-b03a-3ee7aaecc096', E'theory', E'general', E'8', E'Какое определение первичного иммунодефицита наиболее корректно?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:27.366889+00', E'2026-10-25 21:07:27.658135+00'),
  (E'e495d31e-098e-46d8-b53b-011825fa00fc', E'theory', E'general', E'8', E'У ребёнка повторяются бактериальные инфекции, а концентрации всех классов иммуноглобулинов резко снижены; число T-лимфоцитов сохранено. Какое звено вероятнее всего нарушено?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:27.746813+00', E'2026-10-25 21:07:28.040581+00'),
  (E'59fe811f-1572-4f0c-ad3a-7f19f10924ba', E'theory', E'general', E'8', E'Какое осложнение особенно характерно для тяжёлого комбинированного иммунодефицита?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:28.125364+00', E'2026-10-25 21:07:28.419522+00'),
  (E'8102efc9-83c3-4619-814c-f25010a978c9', E'theory', E'general', E'8', E'У пациента с ВИЧ-инфекцией прогрессирующе уменьшается число CD4+ T-лимфоцитов. Какое последствие наиболее непосредственно связано с этим изменением?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:28.525019+00', E'2026-10-25 21:07:28.815741+00'),
  (E'fb61f786-1017-456c-96ec-8c4c4896cfe9', E'theory', E'general', E'8', E'Какой исход наиболее вероятен при тяжёлом комбинированном иммунодефиците без эффективной терапии?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:28.902524+00', E'2026-10-25 21:07:29.201147+00'),
  (E'858ba74a-f43d-4a43-a901-423ddcabc886', E'theory', E'general', E'8', E'Какое определение амилоидоза является наиболее точным?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:29.290307+00', E'2026-10-25 21:07:29.589759+00'),
  (E'4ef9d36d-01c9-409d-b702-f1d00d0f00b5', E'theory', E'general', E'8', E'Какое сочетание правильно характеризует AL-амилоидоз?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:29.674243+00', E'2026-10-25 21:07:29.968039+00'),
  (E'1967d615-d60e-44a0-8dd1-f8ce84258120', E'theory', E'general', E'8', E'Какое сочетание органных изменений наиболее характерно для выраженного почечного амилоидоза?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:30.053556+00', E'2026-10-25 21:07:30.34281+00'),
  (E'59c2d1b6-5243-4a85-b1ab-ed9329d31df5', E'theory', E'general', E'8', E'Какой признак наиболее типичен для макроскопически выраженного амилоидоза печени?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:30.437921+00', E'2026-10-25 21:07:30.726941+00'),
  (E'e7cfce69-a32d-4889-b5d6-59f0d7752888', E'theory', E'general', E'8', E'Какой механизм объясняет поражение сердца при системном амилоидозе?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:30.81932+00', E'2026-10-25 21:07:31.115115+00'),
  (E'11070d93-4d11-4a50-ad30-76daf424a125', E'theory', E'general', E'8', E'Какой фактор наиболее непосредственно способствует развитию AA-амилоидоза?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:31.204343+00', E'2026-10-25 21:07:31.500769+00'),
  (E'0b201ff5-6e74-4264-8f1f-a73a9831922e', E'theory', E'general', E'8', E'Какой принцип классификации амилоидоза наиболее важен для установления патогенеза и выбора терапии?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:31.591178+00', E'2026-10-25 21:07:31.886679+00'),
  (E'a2f1d89a-8a27-4530-a7dd-94b8bf0e1df4', E'theory', E'general', E'8', E'Какое утверждение о причинах смерти при выраженном системном амилоидозе наиболее обосновано?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:32.509183+00', E'2026-10-25 21:07:32.802911+00'),
  (E'220f6034-a2c2-4697-b9bb-4e6c7ca2ef69', E'theory', E'general', E'8', E'При каком варианте иммунопатологии повреждение тканей связано преимущественно с сенсибилизированными T-лимфоцитами и активацией макрофагов, а не с циркулирующими антителами?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:31.976363+00', E'2026-10-25 21:07:32.417681+00'),
  (E'806f8df1-e29a-4a7a-add3-21468cc9bbee', E'theory', E'general', E'5', E'Что способствует тромбозу артерии при атеросклерозе?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:24.798128+00', E'2026-10-29 19:00:25.169954+00'),
  (E'65d0e037-387d-49d6-83aa-d9492c052ad7', E'theory', E'general', E'43', E'Какой путь распространения часто характерен для сарком?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:46.860758+00', E'2026-10-25 22:14:47.178386+00'),
  (E'3f6a3d78-bf73-432c-866d-df19aff261d3', E'theory', E'general', E'10', E'Какой клинико-морфологический признак наиболее важен для опухолей молочной железы при разграничении in situ и инвазивного рака?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:34.279562+00', E'2026-10-25 22:13:34.598835+00'),
  (E'b11b1ac0-628d-4488-9770-bfb52f054c11', E'theory', E'general', E'43', E'Какой набор признаков больше соответствует доброкачественной мезенхимальной опухоли?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:43.144714+00', E'2026-10-25 22:14:43.482113+00'),
  (E'e99ddb32-5886-46ab-a7d2-2b3940692f17', E'theory', E'general', E'43', E'Из чего состоит гемангиома?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:47.268195+00', E'2026-10-25 22:14:47.578349+00'),
  (E'4e6f74cb-dc50-4879-be49-5b890a9ec966', E'theory', E'general', E'43', E'Чем типично различаются капиллярная и кавернозная гемангиомы?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:47.668376+00', E'2026-10-25 22:14:47.983669+00'),
  (E'397c9c0f-e8e1-416e-ab54-b98850386100', E'theory', E'general', E'43', E'Какое осложнение может вызвать сосудистое образование в функционально важной области?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:48.076882+00', E'2026-10-25 22:14:48.402472+00'),
  (E'1cd6dc23-d087-4b21-a78d-d65341528d28', E'theory', E'general', E'43', E'Какие клетки определяют меланоцитарную природу невуса?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:48.491044+00', E'2026-10-25 22:14:48.815371+00'),
  (E'9c8314f8-e973-4231-ab51-b98a7db4bd20', E'theory', E'general', E'43', E'Какой клинический признак особенно настораживает в отношении меланомы?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:48.903961+00', E'2026-10-25 22:14:49.233988+00'),
  (E'df98d849-91fe-4d61-9d75-1d8330e09db1', E'theory', E'general', E'43', E'Что наиболее значимо для морфологической диагностики меланомы?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:49.329967+00', E'2026-10-25 22:14:49.65554+00'),
  (E'5f5abeb2-ff10-4cb9-85b5-97b8e23a0277', E'theory', E'general', E'43', E'Что означает вертикальная фаза роста меланомы?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:49.749101+00', E'2026-10-25 22:14:50.063104+00'),
  (E'bde8fdde-55a2-4436-85dc-d00d902b490f', E'theory', E'general', E'43', E'Почему толщина по Бреслоу важна при меланоме?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:50.15241+00', E'2026-10-25 22:14:50.474081+00'),
  (E'40a83285-fd3a-4c52-877f-0ad9c3dcbd4f', E'theory', E'general', E'43', E'Как правильно сопоставить невус и меланому?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:50.565082+00', E'2026-10-25 22:14:50.899349+00'),
  (E'd8778e9f-15d9-48d8-b931-cffcd06a282c', E'theory', E'general', E'43', E'Какая опухоль связана со шванновскими клетками?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:50.997741+00', E'2026-10-25 22:14:51.316914+00'),
  (E'6155bde6-37e8-4f96-86f6-ede3c3f3b14d', E'theory', E'general', E'43', E'Что характерно для классической шванномы?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:51.404018+00', E'2026-10-25 22:14:51.861619+00'),
  (E'8711bf53-d2f2-4a5e-b557-656ca7dda594', E'theory', E'general', E'43', E'Как нейрофиброма обычно отличается от шванномы?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:51.955738+00', E'2026-10-25 22:14:52.285433+00'),
  (E'b31f562b-154c-4fd2-a7f0-41a8f52fa4e0', E'theory', E'general', E'43', E'С каким наследственным заболеванием связаны множественные нейрофибромы?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:52.374053+00', E'2026-10-25 22:14:52.686944+00');
INSERT INTO public.questions (id, section, block, topic_id, prompt, image_path, is_exam, is_published, created_by, created_at, updated_at) VALUES
  (E'11f43a61-8335-446c-8c00-4af7ad736d77', E'theory', E'general', E'43', E'Какие признаки заставляют подозревать злокачественную опухоль периферической нервной оболочки?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:52.776057+00', E'2026-10-25 22:14:53.08627+00'),
  (E'4f761bfc-f12c-43a9-85ad-218c40197494', E'theory', E'general', E'43', E'Почему опухоли периферических нервов могут вызывать парестезии?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:53.176203+00', E'2026-10-25 22:14:53.487094+00'),
  (E'a228eb13-9893-4294-a17c-0b24cb7af796', E'theory', E'general', E'43', E'Какое утверждение об ангиомах и сосудистых образованиях у детей верно?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:53.580779+00', E'2026-10-25 22:14:53.897249+00'),
  (E'4a109bcc-2b98-4bb3-9cb1-3db07493b227', E'theory', E'general', E'43', E'Как часто ведёт себя инфантильная гемангиома?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:53.986055+00', E'2026-10-25 22:14:54.296335+00'),
  (E'e15608a9-1d5c-4b1c-bcf3-8d75f290fb40', E'theory', E'general', E'43', E'Почему гемангиома рядом с дыхательными путями или глазом требует особого внимания?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:54.386986+00', E'2026-10-25 22:14:54.701278+00'),
  (E'c880d40b-d44f-4f5f-aca6-fd771cd995f1', E'theory', E'general', E'43', E'Что представляет собой нефробластома (опухоль Вильмса)?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:54.793529+00', E'2026-10-25 22:14:55.106837+00'),
  (E'56252a19-62ac-41cf-9319-c897c75669db', E'theory', E'general', E'43', E'Какие компоненты могут присутствовать в классической нефробластоме?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:55.202478+00', E'2026-10-25 22:14:55.528754+00'),
  (E'701d2ce3-0504-476f-8197-fdb6280f5968', E'theory', E'general', E'43', E'Что такое ретинобластома?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:55.623273+00', E'2026-10-25 22:14:55.957054+00'),
  (E'a88601be-c8bd-4edf-bd5e-96984e89ffba', E'theory', E'general', E'43', E'Какой клинический признак может указывать на ретинобластому?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:56.048447+00', E'2026-10-25 22:14:56.364836+00'),
  (E'c5443a93-0151-402b-93a0-04bcf1c8d39a', E'theory', E'general', E'43', E'Что верно для наследственной ретинобластомы?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:56.455832+00', E'2026-10-25 22:14:56.780544+00'),
  (E'24286ab1-1728-49b7-b682-8ceea1036fd7', E'theory', E'general', E'43', E'Какой общий принцип важен для опухолей мезенхимального происхождения у детей?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:56.871454+00', E'2026-10-25 22:14:57.181825+00'),
  (E'eab7dd26-4b0d-447f-b2a6-3f84c2017604', E'theory', E'general', E'43', E'Что помогает установить гистогенез опухоли?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:57.272487+00', E'2026-10-25 22:14:57.58518+00'),
  (E'6f827ef9-c081-4468-94ce-1986affa5c7c', E'theory', E'general', E'43', E'Какой путь метастазирования часто характерен для сарком?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:57.679629+00', E'2026-10-25 22:14:57.99247+00'),
  (E'64faf5c2-3b2b-42c8-b4f3-7937dfcd77ba', E'theory', E'general', E'43', E'Какое сочетание опухоли и ткани происхождения правильное?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:58.085601+00', E'2026-10-25 22:14:58.405429+00'),
  (E'54f28afd-dc83-415a-8d01-d6455056c0d2', E'theory', E'general', E'43', E'Почему макроскопического осмотра недостаточно для надёжного различения невуса и меланомы?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:58.49629+00', E'2026-10-25 22:14:58.805547+00'),
  (E'e7727bde-ab71-474f-8a77-51f81ab987aa', E'theory', E'general', E'3', E'Как классифицируют пигменты по происхождению?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:19.549752+00', E'2026-10-29 18:04:19.911585+00'),
  (E'686b5114-4d43-4167-b993-9a13ffacde47', E'theory', E'general', E'43', E'Как лейомиома матки может проявляться клинически?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:45.62836+00', E'2026-10-25 22:14:45.95038+00'),
  (E'3d168020-a5d4-4f22-8fb5-e8f8d2370971', E'theory', E'general', E'8', E'У пациента с хроническим воспалительным заболеванием выявлены протеинурия, увеличенные плотные почки и амилоидные депозиты. Какое объяснение объединяет клинические и морфологические данные?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:33.274578+00', E'2026-10-25 21:07:33.570402+00'),
  (E'4a7279fa-92b9-4911-9c0e-ca41fd6d90e9', E'theory', E'general', E'10', E'Что означает болезнь Педжета молочной железы в классическом морфологическом описании?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:34.687625+00', E'2026-10-25 22:13:35.008784+00'),
  (E'3a1991dd-8147-4090-92c6-629b10a22708', E'theory', E'general', E'8', E'Какой вывод наиболее корректен при обнаружении амилоидоподобного эозинофильного материала в биоптате без типирования белка?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:33.657438+00', E'2026-10-25 21:07:33.953415+00'),
  (E'be74b242-99f3-4f66-abe4-40358da0511f', E'theory', E'general', E'9', E'Какая триада соответствует классификации регенерации именно по биологическому значению?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:15:48.412375+00', E'2026-10-29 19:15:48.853835+00'),
  (E'650dd3e8-a68e-490e-aac0-18791bee1faa', E'theory', E'general', E'8', E'Какой вариант точнее описывает связь между аутоиммунитетом и иммунодефицитом?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:34.04256+00', E'2026-10-25 21:07:34.330818+00'),
  (E'b5e707a0-11ce-41e2-b8aa-fc1665ad652e', E'theory', E'general', E'43', E'Какие параметры используют при классификации опухолей?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:58.899034+00', E'2026-10-25 22:14:59.214206+00'),
  (E'570e7423-0453-4926-aba2-1da8d57f1dfc', E'theory', E'general', E'8', E'Какой морфологический комплекс наиболее убедительно указывает на клеточно-опосредованное иммунное повреждение, а не на гуморальное?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:34.418105+00', E'2026-10-25 21:07:34.70883+00'),
  (E'f182b2bb-a787-409b-b7e6-4b41f91d1809', E'theory', E'general', E'8', E'Какое утверждение о клиническом значении амилоидных отложений является наиболее точным?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:34.797155+00', E'2026-10-25 21:07:35.113521+00'),
  (E'66a83541-b76d-466c-939e-4770343253e9', E'theory', E'general', E'10', E'Как обычно выглядит инвазивный рак молочной железы макроскопически?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:35.104875+00', E'2026-10-25 22:13:35.417772+00'),
  (E'c1c089aa-0e96-436b-89c0-d7a63dc73cad', E'theory', E'general', E'8', E'Какое сочетание наиболее характерно для реакции гиперчувствительности I типа в тканях?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:35.198594+00', E'2026-10-25 21:07:35.489978+00'),
  (E'46245047-3ce2-42e3-b24b-e1094809770c', E'theory', E'general', E'43', E'Как правильно использовать иммуногистохимию при опухолях меланоцитарной и нервной дифференцировки?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:59.305714+00', E'2026-10-25 22:14:59.625205+00'),
  (E'4c72a3b9-9728-4f57-b806-5c14e2da9c65', E'theory', E'general', E'8', E'При оценке пациента с предполагаемым иммунодефицитом какой подход наиболее обоснован?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:35.582839+00', E'2026-10-25 21:07:35.876993+00'),
  (E'514d2ef7-f521-4743-9165-8d6838ac4cf5', E'theory', E'general', E'8', E'Какой механизм связывает плазмоклеточную дискразию с поражением почек при AL-амилоидозе?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:35.964118+00', E'2026-10-25 21:07:36.261689+00'),
  (E'3d236918-02f7-4710-9881-081054479b59', E'theory', E'general', E'3', E'Какое изменение характерно для антракоза?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:20.008162+00', E'2026-10-29 18:04:20.359305+00'),
  (E'4722c087-b209-459e-b109-b9b2fd8459f7', E'theory', E'general', E'8', E'Какой из перечисленных вариантов лучше всего объясняет, почему при иммунокомплексных заболеваниях часто повреждаются сосуды и клубочки?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:36.348813+00', E'2026-10-25 21:07:36.642673+00'),
  (E'8b87f1dd-3fdc-466f-ad1d-f618c73dd4f9', E'theory', E'general', E'10', E'Какая опухоль наиболее типична для почечной паренхимы у взрослых среди злокачественных эпителиальных новообразований?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:35.511979+00', E'2026-10-25 22:13:35.823437+00'),
  (E'23f183a7-915c-41ef-8bdc-5abae949f3d7', E'theory', E'general', E'8', E'Какое утверждение лучше всего отражает различие между аутоантителом как маркером и аутоантителом как непосредственным эффектором повреждения?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:36.733198+00', E'2026-10-25 21:07:37.030587+00'),
  (E'97fa6af8-ae26-43d0-a5c9-e4f669462c1b', E'theory', E'general', E'3', E'Что называют местным гемосидерозом?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:20.889308+00', E'2026-10-29 18:04:21.228201+00'),
  (E'85a9eb50-6f14-4bb1-b6ca-8e1ff0eb1db8', E'theory', E'general', E'3', E'Что может привести к общему гемосидерозу?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:21.32444+00', E'2026-10-29 18:04:21.653988+00'),
  (E'a6376c05-9f9c-49ce-bcca-24bb61b6aa5a', E'theory', E'general', E'43', E'Из каких элементов преимущественно состоит фиброма?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:44.001672+00', E'2026-10-25 22:14:44.310574+00'),
  (E'b2e8dd1e-51d9-456d-9c59-28d9866be347', E'theory', E'general', E'3', E'Какой пигмент вызывает желтушное окрашивание тканей?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:22.175924+00', E'2026-10-29 18:04:22.50331+00'),
  (E'8028d285-5e77-4bb2-b464-b71508d32197', E'theory', E'general', E'43', E'Что характерно для плотной фибромы?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:44.400037+00', E'2026-10-25 22:14:44.711516+00'),
  (E'c8647970-dcd2-474a-88cd-ef3e2a6f2d0a', E'theory', E'general', E'3', E'Как возникает надпечёночная (гемолитическая) желтуха?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:22.603795+00', E'2026-10-29 18:04:22.976467+00'),
  (E'428c59c9-5042-411d-80b7-52711b941354', E'theory', E'general', E'3', E'Какой признак может обнаруживаться при холестазе?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:23.502211+00', E'2026-10-29 18:04:23.833438+00'),
  (E'49204c65-3d61-4be8-b16d-7aeacfbe0f82', E'theory', E'general', E'43', E'Чем обычно отличается мягкая фиброма от плотной?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:44.806886+00', E'2026-10-25 22:14:45.130935+00'),
  (E'4cd88440-5f10-4f92-86bf-3b175dfa697b', E'theory', E'general', E'3', E'Где может образовываться гематоидин?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:23.933263+00', E'2026-10-29 18:04:24.2454+00'),
  (E'814c8f2f-d794-4add-aef1-3e8121e9b61f', E'theory', E'general', E'43', E'Какой микроскопический рисунок типичен для лейомиомы?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:14:45.222451+00', E'2026-10-25 22:14:45.541465+00'),
  (E'a36d93df-df50-4bca-b579-db9505b602bb', E'theory', E'general', E'3', E'Какова основная роль меланина?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:24.888974+00', E'2026-10-29 18:04:25.239981+00'),
  (E'5951240e-9b01-4cb4-8d4f-421360a0a461', E'theory', E'general', E'3', E'Что означает термин «меланоз»?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:25.339066+00', E'2026-10-29 18:04:25.671657+00'),
  (E'5c0fa65c-7367-4f7b-a6e0-3291f5582883', E'theory', E'general', E'3', E'Что характерно для бурой атрофии?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:26.185402+00', E'2026-10-29 18:04:26.521133+00'),
  (E'e48b761e-66d5-4cce-92b1-47e4194b3c56', E'theory', E'general', E'3', E'Что такое дистрофическое обызвествление?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:26.62153+00', E'2026-10-29 18:04:26.946084+00'),
  (E'e0497c9e-f824-4ac6-8ba8-4fcffd7431a3', E'theory', E'general', E'5', E'Какой общий фактор повышает риск тромбоза?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:25.274239+00', E'2026-10-29 19:00:25.595221+00'),
  (E'6eeab34c-3521-4c3a-b423-680587191222', E'theory', E'general', E'8', E'Какое сочетание наиболее полно отражает основные группы патологических состояний иммунной системы?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 21:07:23.073048+00', E'2026-10-25 22:18:03.897173+00'),
  (E'9c6ae6e5-d81c-45cc-8ac2-0458a0a9296f', E'theory', E'general', E'10', E'Какое макроскопическое сочетание наиболее характерно для почечно-клеточного рака?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:35.914828+00', E'2026-10-25 22:13:36.23155+00'),
  (E'f92de2c3-5c00-43f7-8d9f-bbc704bd44f0', E'theory', E'general', E'3', E'Что такое гемосидерин?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:20.455679+00', E'2026-10-29 18:04:20.789356+00'),
  (E'99dfcfce-a85b-422f-8c29-10b1b9271838', E'theory', E'general', E'3', E'Какое изменение характерно для гемохроматоза?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:21.763723+00', E'2026-10-29 18:04:22.077322+00'),
  (E'1c573ebb-44a4-4bc7-b6fc-9aeb6a4f1450', E'theory', E'general', E'10', E'Что помогает отличить рак почечной паренхимы от рака почечной лоханки?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:36.322679+00', E'2026-10-25 22:13:36.639362+00'),
  (E'7523272a-7cd4-475e-a041-43d740506570', E'theory', E'general', E'3', E'Что характерно для механической желтухи?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:23.075656+00', E'2026-10-29 18:04:23.40493+00'),
  (E'42a3b501-ed13-4510-9a94-05a88aa1ddb1', E'theory', E'general', E'10', E'Какой признак особенно важен при разграничении фолликулярной аденомы и фолликулярного рака щитовидной железы?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:36.727796+00', E'2026-10-25 22:13:37.045786+00'),
  (E'8f701fe4-379c-4a6d-ab1a-fc3e26cec5ed', E'theory', E'general', E'3', E'Что представляют собой порфирины?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:24.343439+00', E'2026-10-29 18:04:24.695948+00'),
  (E'a929c932-f44c-4b31-b305-8096b945bd18', E'theory', E'general', E'3', E'С чем связано накопление липофусцина?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:25.771383+00', E'2026-10-29 18:04:26.086547+00'),
  (E'fabba7bb-224a-4377-ab7e-2d0ca3fe1c3b', E'theory', E'general', E'10', E'Какое утверждение наиболее характерно для папиллярного рака щитовидной железы?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:37.137451+00', E'2026-10-25 22:13:37.451735+00'),
  (E'89fcb18a-8ab7-4f91-bd26-df10c0079def', E'theory', E'general', E'3', E'Что предрасполагает к метастатическому обызвествлению?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:27.044325+00', E'2026-10-29 18:04:27.376932+00'),
  (E'14b755e9-ce5c-4f6d-8e44-7119b2a06073', E'theory', E'general', E'10', E'Какой опухолевый маркер связан с C-клетками щитовидной железы и медуллярным раком?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:37.546763+00', E'2026-10-25 22:13:37.872151+00'),
  (E'b7d67509-86bb-429d-9f1f-7f8b4addefd0', E'theory', E'general', E'10', E'Какой морфологический признак связан с медуллярным раком щитовидной железы в классическом описании?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:37.965698+00', E'2026-10-25 22:13:38.283878+00'),
  (E'78e3e3cd-659f-4284-8f06-d0e20e211515', E'theory', E'general', E'3', E'Где часто выявляют метастатическое обызвествление?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:27.477194+00', E'2026-10-29 18:04:27.808766+00'),
  (E'35f47150-6595-4c46-8a78-2edad4a3810e', E'theory', E'general', E'10', E'Какое описание наиболее точно соответствует анапластическому раку щитовидной железы?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:38.377015+00', E'2026-10-25 22:13:38.693553+00'),
  (E'34568bac-bd25-4ee8-9261-e5333a1e4274', E'theory', E'general', E'10', E'Какая особенность наиболее характерна для доброкачественной папилломы кожи?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:38.784193+00', E'2026-10-25 22:13:39.099999+00'),
  (E'61ebf849-8e92-4aa6-985b-abcfc8f6856b', E'theory', E'general', E'3', E'Как выявляют железо в гемосидерине гистохимически?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:27.91525+00', E'2026-10-29 18:04:28.231403+00'),
  (E'28cdb4a6-688c-4b7d-84a4-09aaf0c9e902', E'theory', E'general', E'10', E'Как следует трактовать базально-клеточный рак кожи (базалиому) в классическом морфологическом описании?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:39.191624+00', E'2026-10-25 22:13:39.504833+00'),
  (E'9168ff2e-aefe-44b3-b146-cedbc1d74063', E'theory', E'general', E'10', E'Какой микроскопический признак характерен для базалиомы?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:39.601811+00', E'2026-10-25 22:13:39.914792+00'),
  (E'98b726d8-eb02-4c3f-9f6d-38fed3446f64', E'theory', E'general', E'3', E'Что такое некроз?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:28.322308+00', E'2026-10-29 18:04:28.662673+00'),
  (E'b2964d65-c0b9-4537-bbec-0a2aabc7132f', E'theory', E'general', E'10', E'Какой вариант наиболее правильно сопоставляет опухоль кожи и её тканевое происхождение?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:40.00523+00', E'2026-10-25 22:13:40.321657+00'),
  (E'b434c161-1fb3-4e6e-8188-44b2561d3246', E'theory', E'general', E'10', E'Какой признак делает опухоль кожи подозрительной на инвазивный плоскоклеточный рак, а не на доброкачественную папиллому?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:40.416203+00', E'2026-10-25 22:13:40.73356+00'),
  (E'ede649d1-b77c-4ab4-a316-a51f95814b42', E'theory', E'general', E'3', E'Какая последовательность ядерных изменений характерна для некроза?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:28.763829+00', E'2026-10-29 18:04:29.104418+00'),
  (E'a658a61b-51dc-4757-9f22-2cb61a66ce20', E'theory', E'general', E'10', E'Какой вывод наиболее корректен при оценке опухоли по степени дифференцировки?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-25 22:13:40.826506+00', E'2026-10-25 22:13:41.129704+00'),
  (E'42d6d416-fc55-40ed-8ac2-b23f9dd5da84', E'theory', E'general', E'3', E'Какой признак характерен для коагуляционного некроза?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:29.209966+00', E'2026-10-29 18:04:29.77236+00'),
  (E'13c5d885-6f2b-4345-88fe-ca305acee4a3', E'theory', E'general', E'3', E'Для какого некроза характерно ферментативное разжижение ткани?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:29.896158+00', E'2026-10-29 18:04:30.23555+00'),
  (E'55439946-1264-4de1-b551-af9fde586c6d', E'theory', E'general', E'3', E'Какой вариант некроза типичен для туберкулёзного очага?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:30.330864+00', E'2026-10-29 18:04:30.721971+00'),
  (E'a0c38049-e60e-4f49-ac94-ffbc1b6cfef2', E'theory', E'general', E'3', E'Чем гангрена отличается как клинико-морфологическая форма некроза?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:30.820635+00', E'2026-10-29 18:04:31.160354+00'),
  (E'10bc2af8-fd6f-4fc4-93db-08ebb48180e6', E'theory', E'general', E'3', E'Как выглядит сухая гангрена?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:31.270582+00', E'2026-10-29 18:04:31.619069+00'),
  (E'796f46f7-f882-4ae6-b512-5b986e93dc2a', E'theory', E'general', E'3', E'Что способствует влажной гангрене?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:31.711871+00', E'2026-10-29 18:04:32.030708+00'),
  (E'bdf767c9-35a0-47b8-9883-7b9373838b42', E'theory', E'general', E'3', E'Что такое инфаркт?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:32.125562+00', E'2026-10-29 18:04:32.451337+00'),
  (E'9dff5a62-a165-4120-846b-51a3b4b86dce', E'theory', E'general', E'3', E'Какой инфаркт типичен для почки и селезёнки?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:32.556866+00', E'2026-10-29 18:04:32.952719+00'),
  (E'04ad6836-507d-4d55-9933-a67c70771653', E'theory', E'general', E'3', E'Когда вероятнее развивается красный инфаркт?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:33.051683+00', E'2026-10-29 18:04:33.375271+00'),
  (E'2e09fd82-2ce5-463d-9248-f57d9c16fa3b', E'theory', E'general', E'3', E'Каков частый исход инфаркта?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 18:04:33.484936+00', E'2026-10-29 18:04:34.093446+00'),
  (E'd68ca4c2-0710-4578-937f-f2d791435499', E'theory', E'general', E'5', E'От чего зависит развитие некроза при ишемии?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:00:39.806996+00', E'2026-10-29 19:00:40.133729+00'),
  (E'90069419-473a-4bae-8132-2980c359a66b', E'theory', E'general', E'9', E'После повреждения ткани число клеток увеличилось за счёт митотического деления сохранившихся клеток-предшественников. Какой механизм регенерации реализуется?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:15:48.965799+00', E'2026-10-29 19:15:49.373098+00'),
  (E'72976e34-b631-4c6e-b365-93a49ba190a5', E'theory', E'general', E'9', E'Какова типичная последовательность основных этапов заживления раны?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:15:50.650427+00', E'2026-10-29 19:15:51.100069+00'),
  (E'ec77f65f-6b11-41cc-bdce-31a64df0dcdb', E'theory', E'general', E'9', E'Для раны с большой потерей ткани и расхождением краёв наиболее характерно заживление вторичным натяжением, при котором', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:15:52.344251+00', E'2026-10-29 19:15:52.802006+00'),
  (E'390e94a5-04d6-491c-9544-9812d31e789a', E'theory', E'general', E'9', E'Какое изменение наиболее характерно для гиперрегенерации, а не для нормального созревания раны?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:15:52.924317+00', E'2026-10-29 19:15:53.351893+00'),
  (E'9cfb822a-ae46-4fad-9487-739d46a3640c', E'theory', E'general', E'9', E'У пациента после обширного инфаркта миокарда некротический очаг постепенно замещается соединительной тканью. Какой механизм и исход описаны?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:15:55.352216+00', E'2026-10-29 19:15:55.908004+00'),
  (E'c56e75e2-4bc3-440b-919d-9726e80a7cbe', E'theory', E'general', E'9', E'У пациента с длительной артериальной гипертензией ранее утолщённый миокард становится дряблым, полости сердца расширяются, появляются застой и сердечная недостаточность. Это указывает на', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:15:57.24317+00', E'2026-10-29 19:15:57.716906+00'),
  (E'62af2f62-fcac-48bf-8618-5c18d44125d4', E'macro', E'specific', E'12', E'Определите патологический процесс по макропрепарату.', E'360:storage:4efcd4a8-c8e4-488a-955a-2cf97aae40f2', E't', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-11-21 22:39:58.467664+00', E'2026-11-21 22:39:58.944464+00'),
  (E'7646afbc-1ac6-4d80-a14a-b3647ff976d7', E'theory', E'general', E'9', E'Какое сочетание изменений наиболее типично для атрофии органа при световой микроскопии?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:16:00.844895+00', E'2026-10-29 19:16:01.260486+00'),
  (E'f22a4661-584a-4b2d-9a1e-2c456316a984', E'theory', E'general', E'9', E'В очаге некроза обнаружены прорастающие капилляры и фибробласты, позднее формируется рубец. Как называется этот процесс?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:16:02.441814+00', E'2026-10-29 19:16:02.926674+00'),
  (E'a1feb048-1f71-44ac-b79b-ba504a5077a7', E'theory', E'general', E'9', E'Какое наблюдение наиболее убедительно свидетельствует о патологическом течении регенерации?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:16:04.122877+00', E'2026-10-29 19:16:04.662164+00'),
  (E'65c89d3e-da5f-4956-ba0f-43edb1b370e3', E'theory', E'general', E'9', E'У курильщика хроническое раздражение бронхов сопровождается заменой мерцательного цилиндрического эпителия многослойным плоским. Как трактовать изменение?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:16:05.828076+00', E'2026-10-29 19:16:06.254254+00'),
  (E'9a29bd7c-180d-4661-9224-4f3a788ffc07', E'macro', E'specific', E'15', E'Определите патологический процесс по макропрепарату.', E'360:storage:77a75e99-8785-47a0-9832-de1dc5c4087c', E't', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-11-21 22:54:53.528719+00', E'2026-11-21 23:05:16.90124+00'),
  (E'672a576d-b68a-4d45-855c-c7d2cb2e1729', E'theory', E'general', E'9', E'Почему длительная гипертрофия миокарда может перейти в декомпенсацию?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:16:06.365293+00', E'2026-10-29 19:16:06.783817+00'),
  (E'8536da9b-ec01-4f2e-a105-83ac1a53911b', E'theory', E'general', E'9', E'Каков наиболее вероятный исход обширного некроза в ткани с низкой способностью к клеточной регенерации, например в миокарде?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:16:06.90822+00', E'2026-10-29 19:16:07.314046+00'),
  (E'd056ee91-31d7-41d6-83a7-9cbdcbcf9f5d', E'theory', E'general', E'9', E'Какое сочетание факторов наиболее существенно нарушает заживление раны и может поддерживать хронический дефект?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:16:07.960977+00', E'2026-10-29 19:16:08.384231+00'),
  (E'3f171061-872a-414d-9fc7-f58a5eb226cd', E'theory', E'general', E'9', E'После резекции части печени объём органа постепенно увеличивается за счёт размножения сохранившихся гепатоцитов. Какой процесс преобладает?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:16:08.502977+00', E'2026-10-29 19:16:08.924513+00');
INSERT INTO public.questions (id, section, block, topic_id, prompt, image_path, is_exam, is_published, created_by, created_at, updated_at) VALUES
  (E'dce006bf-13a0-49c7-ae03-0295745daae5', E'theory', E'general', E'9', E'При хроническом повторном повреждении органа гибель клеток и репарация чередуются, но нормальная архитектоника постепенно нарушается. Какой исход наиболее вероятен?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:16:09.045842+00', E'2026-10-29 19:16:09.47118+00'),
  (E'5de3a7a1-c24c-457f-8af4-d5d11fa13735', E'theory', E'general', E'9', E'Какая классификация регенерации построена по биологическому значению процесса, а не по механизму или результату?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:16:09.61367+00', E'2026-10-29 19:16:10.046164+00'),
  (E'c5bea212-de3a-473b-b2c1-ed0d31fd66e1', E'theory', E'general', E'9', E'Какой набор включает основные адаптивные изменения клеток и тканей, рассматриваемые в патологической анатомии?', NULL, E'f', E't', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-10-29 19:16:10.169884+00', E'2026-10-29 19:16:10.606885+00');



--
-- Data for Name: site_content; Type: TABLE DATA; Schema: public; Owner: -
--

-- Imported 4 rows into public.site_content
INSERT INTO public.site_content (key, value, updated_at, updated_by) VALUES
  (E'hero_image', E'https://cdn.britannica.com/49/144349-050-97292591/Heart-tissue-myocardial-infarction-form-signs-contraction.jpg', E'2026-10-23 18:28:14.181572+00', NULL),
  (E'left_quote', E'«Болезнь — это жизнь при ненормальных условиях»', E'2026-10-23 18:28:14.294776+00', NULL),
  (E'right_quote_image', E'', E'2026-10-23 18:28:14.404678+00', NULL),
  (E'right_quote', E'Hic locus est, ubi mors gaudet succurrere vitae', E'2026-10-23 18:28:14.514366+00', NULL);



--
-- Data for Name: topics; Type: TABLE DATA; Schema: public; Owner: -
--

-- Imported 22 rows into public.topics
INSERT INTO public.topics (id, block, title, sort_order, is_locked, is_locked_macro, is_locked_micro, is_locked_theory) VALUES
  (E'2', E'general', E'Повреждение: стромально-сосудистые дистрофии', E'2', E'f', E't', E't', E'f'),
  (E'15', E'specific', E'Патологическая анатомия желудочно-кишечного тракта', E'4', E't', E'f', E't', E't'),
  (E'4', E'general', E'Расстройства кровообращения: полнокровие, кровотечение, кровоизлияние', E'4', E't', E't', E't', E'f'),
  (E'5', E'general', E'Тромбоз, эмболия, ишемия', E'5', E't', E't', E't', E'f'),
  (E'6', E'general', E'Острое воспаление. Экссудативное воспаление', E'6', E't', E't', E't', E'f'),
  (E'8', E'general', E'Иммунопатологические процессы', E'8', E't', E't', E't', E'f'),
  (E'9', E'general', E'Адаптация: регенерация, гипертрофия, атрофия', E'9', E't', E't', E't', E'f'),
  (E'7', E'general', E'Пролиферативное воспаление', E'7', E't', E't', E't', E'f'),
  (E'43', E'general', E'Опухоли мезенхимальные, меланинобразующей и нервной тканей', E'11', E'f', E't', E'f', E'f'),
  (E'11', E'general', E'Гемобластозы', E'11', E't', E't', E't', E't'),
  (E'10', E'general', E'Общее об опухолях. Эпителиальные опухоли', E'10', E't', E't', E't', E'f'),
  (E'3', E'general', E'Смешанные дистрофии и необратимые повреждения живых структур', E'3', E't', E't', E't', E'f'),
  (E'14', E'specific', E'Болезни органов дыхания', E'3', E't', E't', E't', E't'),
  (E'16', E'specific', E'Заболевания печени и поджелудочной железы', E'5', E't', E't', E't', E't'),
  (E'21', E'specific', E'Инфекции', E'10', E't', E't', E'f', E't'),
  (E'18', E'specific', E'Заболевания половой системы', E'7', E't', E't', E't', E't'),
  (E'20', E'specific', E'Болезни эндокринной системы', E'9', E't', E't', E't', E't'),
  (E'13', E'specific', E'Болезни сердца', E'2', E't', E't', E't', E't'),
  (E'19', E'specific', E'Патология беременности и послеродового периода', E'8', E't', E't', E't', E't'),
  (E'12', E'specific', E'Болезни сосудов', E'1', E't', E't', E'f', E't'),
  (E'17', E'specific', E'Заболевания почек', E'6', E't', E't', E't', E't'),
  (E'1', E'general', E'Повреждение: паренхиматозные дистрофии', E'1', E'f', E't', E't', E'f');



--
-- Data for Name: turntable_sets; Type: TABLE DATA; Schema: public; Owner: -
--

-- Imported 15 rows into public.turntable_sets
INSERT INTO public.turntable_sets (id, title, frame_paths, created_by, created_at) VALUES
  (E'4111c417-53c0-4d94-acf7-1d9869832bb7', E'fadsads', E'["turntables/42a39ae8-7b29-4a8e-b064-c286f681b1e4.png", "turntables/6af314e0-2e91-49b0-9fe5-a70b54498f9c.jpg", "turntables/7eb6aac0-4f9f-4548-adab-47e6208e1c87.jpg", "turntables/076efa46-b044-4476-bac9-ccda6b99fc48.jpg", "turntables/abdf72d2-0089-4407-b0b7-01b775aae13e.jpg"]', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-11-19 17:01:01.298398+00'),
  (E'7a2ddc92-633e-449f-bc47-3b9d13040384', E'Папиллома кожи', E'["turntables/156c1f4f-536b-493c-b786-38281c42a2b7.jpg", "turntables/e4737b39-832c-4e54-b086-a05cca801730.jpg", "turntables/72560ce4-919a-49b9-9307-cd1be8fc833c.jpg", "turntables/9cfe6d82-66e4-4673-b0f1-68714f9ffb76.jpg", "turntables/3fb37e67-2fab-4033-b481-179425a3b25e.jpg", "turntables/3c523916-e4f7-4388-8504-6702b1b6b04b.jpg", "turntables/9c1fff57-24a1-4437-8d03-1dbc56e1d5fc.jpg", "turntables/866aa6e2-ca86-4127-a7bb-2d4daa5e6c8d.jpg", "turntables/380ac62b-b8ba-45e0-926a-4dc417a80452.jpg", "turntables/f07bec75-7ff3-4310-ab69-6aa2fc56eab8.jpg", "turntables/4c07c906-82eb-48f0-8802-5b1729ab10d0.jpg", "turntables/c2914d9f-7319-4cb7-95a2-01a1439a62c9.jpg", "turntables/b16c6224-579a-4b92-9702-13c17640c243.jpg", "turntables/9f3bdf69-a630-4882-b413-777330ce728b.jpg", "turntables/4a29c96a-c269-4264-983a-66aa55da88ed.jpg", "turntables/987e7066-7634-4718-9a79-b7c059d732ef.jpg", "turntables/c733c539-e008-45b8-ab9c-5192b35ca712.jpg", "turntables/3ad9f79a-d7fc-4e02-8434-9fe65486ab96.jpg", "turntables/78b1a9cc-228b-4c2c-805e-43651bc89864.jpg", "turntables/398814f8-b868-4314-b63f-d86be945000e.jpg", "turntables/a1695197-1332-402d-88b1-2b24724e3c93.jpg", "turntables/2eddcd62-b436-4527-b0ec-8537bf20e4d7.jpg", "turntables/9fbe992d-5c05-4fc9-a720-535a138e8250.jpg", "turntables/bee35806-28cf-4c26-b084-2389accde4a6.jpg", "turntables/34fe443f-7920-47c5-900d-73260129f1b1.jpg", "turntables/c0e07db1-558a-4273-a065-aeab437118d3.jpg", "turntables/9042dd05-8c35-4216-86e6-9bc01dbb749e.jpg", "turntables/44c64b00-178d-4763-921b-98ae25051bf3.jpg", "turntables/f721aaa3-fe9c-47b0-816b-0a546f76237f.jpg", "turntables/f06e9c7f-af25-4aa3-8e60-837de3b00c41.jpg", "turntables/dd628b64-0a14-4653-bd04-eb7ff44cd348.jpg", "turntables/a19f1045-34b4-46cf-8b44-11f43e994035.jpg", "turntables/5104a31f-1457-4a68-b91d-ecb7dfef0671.jpg", "turntables/85adf3a9-ebdc-4e18-b76c-6f656b8d21fd.jpg", "turntables/013d1867-b4ed-494f-8d90-49f56565875f.jpg", "turntables/9cb64796-d281-4736-a67f-0024aaba3165.jpg", "turntables/ad6cc931-bf2f-4a47-8176-19b977c81a9d.jpg", "turntables/95302cbd-09fd-4fd6-ad42-e2b302126c94.jpg", "turntables/ecfc5d55-de2b-49ff-81b5-4654cf6e2de2.jpg", "turntables/b54b67ac-d617-46a2-8202-83950e7e6c8e.jpg", "turntables/91763363-5e1c-47b0-9006-fabbe77c2781.jpg", "turntables/f118cd5b-297f-4c5b-bed0-eed968bde002.jpg", "turntables/543e506b-27cb-4a53-afa4-8a6bb70a953b.jpg", "turntables/2e42addc-e26d-4709-ad37-c7dd09ef2198.jpg", "turntables/30cde4c7-c6d0-4fc1-81f6-40cbe7fd8733.jpg", "turntables/d0d75cbc-ec82-41d1-a1e0-3a480039e277.jpg", "turntables/8428780b-9a11-472d-b860-7d5d6c20bab4.jpg", "turntables/f3ad79e6-4a9a-4d9a-b98e-489b465cba4a.jpg"]', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-11-19 17:28:04.681349+00'),
  (E'46c6dda2-ea5e-4540-a329-3e2e1ec88ad3', E'Жировая дистрофия печени', E'["turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/50c3a223-342d-4e7f-996a-dcf51d54d2e0.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/f7156156-0b69-4a75-b6ca-3ac45bca5422.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/46007aa4-1aa9-493f-8556-9263453bf221.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/6455785b-fee4-47a5-90f5-ba1b6f7b555b.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/36ea6602-d2a2-4735-95f5-8d4107e0d783.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/4335d212-a454-49f3-bf4f-d07466223a6d.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/1a98edf0-c08e-49b8-9af9-01f6af42d5bd.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/50a35ffe-601c-47f9-9c98-e81dc97a246a.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/7b53e0eb-8dd5-4752-b656-6e9fe2338a76.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/033214ef-ea2f-4b82-9e93-93e9ae667fd5.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/6ceaebad-698c-4fe0-8fbe-4a3d2f770139.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/24040499-7207-4864-8540-dce0ccd41692.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/413edde0-009b-4731-80f8-f56d2187fd62.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/dccccaa6-2d5b-498b-8309-ccebf3a9e4b2.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/2b87dfb7-ad3c-43d9-8ca9-cd20aac6b44c.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/89922d01-e834-46c1-96d2-0ce093f72d30.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/040244ab-897d-4e66-ac4a-607ac6e548d3.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/a361855f-8a18-43ed-8891-d55f0549310f.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/759b2e69-4d59-4680-8c49-55a31d1c02e2.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/8aa9bcc9-aa5c-4b8f-9add-52eb7ce4805b.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/3f436c90-e111-4978-bfaf-71cd7ecb7e7a.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/44e7d176-bcd7-45b1-ae31-a14e96b773da.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/b46ff2b7-b79b-45e5-88b0-96890d7cef78.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/0251c21d-7599-4eba-a228-65e0179146c2.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/073c0c05-a418-44ea-b4e7-473e77e2eef9.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/c511ceca-f22f-423d-93ed-8b0a3fc791f4.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/0cb00d1e-ef87-4e23-bd56-0634346a10e2.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/46d1d9f5-c63c-489b-9c74-f63120cabb61.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/0e8a7fa5-3c1a-4835-aca5-d9a6b12a9881.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/90b4f6b8-c1ee-4bf9-ab84-d5a3643bcaed.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/d3978048-c420-48ec-aa62-468f81985681.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/2ba0d1b0-a569-4b33-b493-3571bc266a19.jpg", "turntables/46c6dda2-ea5e-4540-a329-3e2e1ec88ad3/7d9fc132-8656-4fdd-9fa6-d6287b668861.jpg"]', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-11-21 22:49:57.026647+00'),
  (E'0dc587f4-73b1-4c50-b4d7-3840256e928e', E'вап', E'["turntables/13d90fce-428e-4515-8b95-6dcadf78745c.jpg", "turntables/9b443fc8-dddd-4af0-8341-8ffc107842a8.jpg", "turntables/fb9b6b9b-fede-41a5-9785-801921444a89.jpg", "turntables/cc4bbe94-b622-4460-a285-a7e29f1edf16.jpg", "turntables/5923714e-6ac6-49b3-89fc-2ad58e5c1f1d.jpg", "turntables/1b7b9620-9295-48cb-9b61-f994b7cd1d46.jpg", "turntables/59129c22-1c8c-4d9c-9d39-0d5af5b2243a.jpg", "turntables/fa489f13-0794-48a9-9382-7bce9d9ad143.jpg", "turntables/2f662de4-e0a1-4ba2-97af-9f9b89133c1a.jpg", "turntables/5ddd692c-a672-48d4-aae6-e286b9bb9342.jpg", "turntables/84d4af00-00e1-4316-af78-253d7c8da464.jpg", "turntables/2b7eb039-64e0-4b87-86a3-64fc5efb0502.jpg", "turntables/d6c4e41d-de40-4ee8-9236-0fd128ff3134.jpg", "turntables/07707fe0-5b67-4199-959a-aa8e1db802a5.jpg", "turntables/edac2d14-23d9-4ae4-95ef-64ca7674d0ea.jpg", "turntables/f780a76b-5dc5-4e80-a5a8-fd70ea0fdf74.jpg", "turntables/2fada846-27f2-4e76-aabc-5e37a51213fe.jpg", "turntables/15a9dbe5-059e-493d-8e2d-2f1ad80a4465.jpg", "turntables/91c53c57-1be2-4bca-8994-ffbdaf764f85.jpg", "turntables/b8d72b8e-657a-4e6a-81d5-046800af1c10.jpg", "turntables/86a8523e-8413-4520-9c59-fd2ca3e2c37e.jpg", "turntables/bff126c7-e988-4bbe-b0c7-5ee4f9572445.jpg", "turntables/3aaed618-cc8a-48b6-8aea-679018fbb110.jpg", "turntables/4d1a2b16-8520-4b58-998a-c00119651d0b.jpg", "turntables/08bf3d8b-41f1-4dc8-b425-29ce4738b416.jpg", "turntables/a19ff502-575d-4e01-bb23-6f2d480eaef3.jpg", "turntables/c7cfe81c-9863-4e77-8c1a-ab1c1922b689.jpg", "turntables/b08fcb3a-4e47-4203-88e2-0ad598b56f23.jpg", "turntables/2776bde3-9f1e-43a7-8003-42d0caae0707.jpg", "turntables/ba4b69e1-c409-49b8-b4a4-21a26657bb13.jpg", "turntables/c6ae259e-8c12-454c-b980-293523e282c7.jpg", "turntables/4c0c1287-cfb4-46e0-a6ff-779e3891d039.jpg", "turntables/3386c5cb-4f6b-447e-8114-60330dec9eaf.jpg", "turntables/c2bda525-cde0-46ed-b8a6-b02178117b86.jpg", "turntables/698c14be-f43b-4d33-830c-2e3b1b9e6dc0.jpg", "turntables/c8cfdf6f-8c55-430f-9519-8111bda143a8.jpg", "turntables/e53bc969-960d-4d2f-a2ed-d9b9159f7ca7.jpg", "turntables/dfd8cadb-d7d8-4f73-9f1c-ee1b8ac501ba.jpg", "turntables/efd9999c-e4e2-4c40-abb1-a3d23840cf76.jpg", "turntables/46b1cd81-467b-4c77-94bb-f6123e5e3b84.jpg", "turntables/47dfddc7-d7c6-49ff-96de-3af4c9c0b448.jpg", "turntables/6365d277-001d-4282-95b7-285e6a9b3cea.jpg", "turntables/9cb08a69-2ac8-4568-a346-7a0054801622.jpg", "turntables/e24021c3-8d7d-400a-acb2-f937fa7cb7a9.jpg", "turntables/aa33d240-aa3b-467b-8956-552de3c73814.jpg", "turntables/7589c0eb-123a-480e-aa1c-4cae00eb038a.jpg", "turntables/93c69d55-4d50-4959-8d84-36e0682743a1.jpg"]', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-11-19 17:51:28.071207+00'),
  (E'52619141-8496-4a5f-9fdd-9cb11ced3e38', E'ва', E'["turntables/f1357eae-12d8-4994-9c0d-6c685efee336.jpg", "turntables/047636a0-4c4b-4d66-94f9-4f34170b5197.jpg", "turntables/52064b3c-f2e6-4791-86a4-b146c7cd162b.jpg", "turntables/912e295f-26d3-485a-94ae-7d0361e2b6e8.jpg", "turntables/53fe95b1-0b7c-41c9-afd5-f57dcfc82cf3.jpg", "turntables/072706b5-2919-481d-b790-bc4da12b2c06.jpg", "turntables/d64d0e82-69fd-428b-91fb-69dd87fa536f.jpg", "turntables/7120cc5e-55fd-47a6-b90b-1a0d31a81d76.jpg", "turntables/1906c972-3226-499a-8e87-c16d70c0c5c8.jpg", "turntables/3f64ca54-7b11-417a-83fb-e86f2133a5ba.jpg", "turntables/b8f1f1ac-ab8d-4b81-9cbe-8e747024a716.jpg", "turntables/eeb20d76-6639-473b-8ac4-e344b76ad7ee.jpg", "turntables/d1ab8ec5-9b8f-4c56-9201-6254d8f526a6.jpg", "turntables/f17fc818-9cd4-4b84-b871-1f1753bb115e.jpg", "turntables/85d22c10-e8e5-4336-96af-60cc9042bf24.jpg", "turntables/bee724fc-3a35-4b25-af41-99d6a06acaec.jpg", "turntables/9103c6b2-4820-4216-8359-24f26b4bb864.jpg", "turntables/929c8720-22f2-44b4-9e8b-d6f7994b20ef.jpg", "turntables/f2b522da-06b4-4c5e-8596-818416485e6a.jpg", "turntables/b3dddf5e-2160-4eef-8e87-9ef9666b4ca0.jpg", "turntables/95b9f95c-58af-4122-b5ae-4de6e9ad1f5e.jpg", "turntables/6db80fc1-7d5b-46ef-a00a-83a0fb81b0a3.jpg", "turntables/b7447c8e-2e6d-418b-8c68-07d943189a0d.jpg", "turntables/3e002877-2276-4c16-9b4f-4d9d314495a7.jpg", "turntables/eb03b750-15ad-4fc6-a6f9-ccde50035b7b.jpg", "turntables/3b137f18-7461-4560-9b22-b5e1f8bb79f3.jpg", "turntables/9d79ea63-8c58-42e1-a679-9a58205f1e15.jpg", "turntables/0d0fbffb-9508-4256-83e0-f4405a9ff6fe.jpg", "turntables/bda847e8-eba0-4ea6-b9cb-147ac2ade172.jpg", "turntables/8387b708-9f0b-4019-8212-6ea991cda586.jpg"]', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-11-19 19:14:51.866747+00'),
  (E'c3361ad1-0cf7-48a6-80eb-2f6010842e88', E'эмфизема буллезная', E'["turntables/6d372625-464f-48e3-90c2-440e7798ba65.jpg", "turntables/5601096c-7bea-4d9f-907b-9a97635e6a3b.jpg", "turntables/5fddbc63-eae6-433e-9e24-b337c1d80cb4.jpg", "turntables/e1861a67-642b-4e47-98dd-c719a9ab9ef2.jpg", "turntables/114e21f6-4a30-4b0c-997a-4ca2b6c9ed74.jpg", "turntables/c3f37f7a-c83a-4657-aa4c-cc684675b72c.jpg", "turntables/9c7e86fa-cd43-4a5c-b998-0d58bcdba252.jpg", "turntables/d02d6bb0-09fd-4ffb-b298-319da0866f36.jpg", "turntables/13d100f2-1127-461e-8e13-9f0af0403b20.jpg", "turntables/5cfd3b58-c4c9-492c-a833-7e80dafd2295.jpg", "turntables/b979ecfc-838e-40ab-85f8-6aaf8c46db03.jpg", "turntables/0ce7fe21-4c7e-48b6-a00b-9a1734386fc9.jpg", "turntables/2c176585-f559-4f4d-9ec7-80b859761462.jpg", "turntables/d5cabbd9-a27d-4191-a893-4d9646422b26.jpg", "turntables/bf7dd9ce-abb1-42bf-8073-0be0d0895ad6.jpg", "turntables/115cfe6f-990e-46ee-b62b-dc957ba7a92b.jpg", "turntables/5b84fab1-e7c1-42d0-b342-a7389a2b5fa8.jpg", "turntables/e3114082-610b-46c7-a97a-14e4d2bf526e.jpg", "turntables/d27cf7bb-0f68-4ad8-8aa7-46f123e50578.jpg", "turntables/b91ddf01-fb74-433c-94b3-a8a7c0befa99.jpg", "turntables/9f1cd40d-fb4b-4b8a-a4a8-b33ec5cff199.jpg", "turntables/001b1170-115f-4116-974a-8d11b5dfd74b.jpg", "turntables/1cc7e5c7-9407-4fc6-814d-59294b6cf7f1.jpg", "turntables/8b312ae8-46fb-4b95-b8fa-a3069b87634f.jpg", "turntables/e51d81f6-ab6c-428a-9bd5-1894a80d29d4.jpg", "turntables/fc2e8f09-9e80-4de3-a047-636300c9a66e.jpg", "turntables/7f0e8b62-6cc1-42c9-971e-11df280ac974.jpg", "turntables/47cc0360-7bbf-43e5-b521-6f8954174064.jpg", "turntables/9a3e738e-8545-43c4-9408-aaaea45a1ca3.jpg", "turntables/61a27c73-f785-4605-82b6-f06288fde55d.jpg", "turntables/4ffc5688-6444-4809-b1c4-29bb888e2690.jpg", "turntables/13453ac2-6801-4c4f-83fe-1cfe59ffe631.jpg", "turntables/32d14766-fed6-41c9-9fa7-e1d728fec2e7.jpg"]', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-11-19 19:55:13.938158+00'),
  (E'41e81338-a044-492b-b615-f78ca01c0fdb', E'ы', E'["turntables/c64da489-6fe2-4d72-a609-d642dacfb933.jpg", "turntables/f8056786-4582-434a-9e24-c29046ebb8da.jpg", "turntables/6eef24f6-0abf-46ca-ad6f-97142ebb44ab.jpg", "turntables/6d278fbd-5acc-45eb-9684-3d77dd3ed239.jpg", "turntables/105c992a-4875-474f-9de7-bef9c504a2ce.jpg", "turntables/4987af52-c234-4e6a-8e2c-c84de4aa85f2.jpg", "turntables/9920a3cc-3928-4079-8c4c-1c4ae21f3d83.jpg", "turntables/940fb7c9-71e0-4ad2-bdeb-e5c263403326.jpg", "turntables/28fe85fa-5b6f-48ff-9d48-22bf9b2fdfc3.jpg", "turntables/ae6255bc-0130-4ae8-be24-e40645147c7e.jpg", "turntables/7f249f67-b4b9-4dea-b9d5-01dbf2d67cc8.jpg", "turntables/99a358e8-b877-4da2-be83-9c8ec79a98f0.jpg", "turntables/accece0a-9ffa-423e-8bd1-642872e482dc.jpg", "turntables/05b57387-9554-42ca-b924-6938b63232dd.jpg", "turntables/1fb2f1be-2453-4566-ad12-e85b91691ff5.jpg", "turntables/323fe76a-69ac-4fc2-8225-5aee62ea7e97.jpg", "turntables/00f952ed-92fe-48f9-851a-02f9bc86676e.jpg", "turntables/719076cf-b936-409f-b93c-7ad210c05af8.jpg", "turntables/59d7f052-120c-4d37-af5b-ed485579b5a6.jpg", "turntables/9098e102-23e9-4a34-a162-cd5be4ffa75d.jpg", "turntables/e96345de-bffb-4093-8651-7706d9d7553c.jpg", "turntables/cebec8f9-90f5-4a02-bfd9-ab3d549249cc.jpg", "turntables/91856992-bc8c-478a-bd57-629b081972c7.jpg", "turntables/946184c4-0cb8-40a3-989b-6562da93b816.jpg", "turntables/74561997-dd8b-4ec9-93ad-f9c96cf0f425.jpg", "turntables/f5fb8520-b0f6-4e28-8c6b-7eff8fe9196c.jpg", "turntables/9018b3a3-7032-423b-b2ee-d2e201ef04e8.jpg", "turntables/660c00ab-f762-41f7-9d13-0bd30ea4e109.jpg", "turntables/e88a7939-4a98-44e9-942f-b342421bc701.jpg", "turntables/23c0270a-a534-4a7d-a1ab-43a604f14693.jpg", "turntables/ded02aa4-3e1e-4b32-9a15-4b79fcebb039.jpg", "turntables/9ab973ee-57d6-49b6-8a0e-6b5392a5257d.jpg", "turntables/9a980b02-6ae0-4de2-bf1e-090eb11b8587.jpg", "turntables/9b7e716b-5915-41c8-9d5e-0affd3909df6.jpg", "turntables/3fb110c3-c681-4bec-9658-626339755828.jpg", "turntables/644578ec-5ce0-4e2d-b185-245204d901a1.jpg", "turntables/96e79785-e131-4dfa-900c-e791883d928f.jpg", "turntables/3820e276-5076-41fa-b5eb-5d5092e9fc8d.jpg", "turntables/6724d3f9-6bf2-47fc-b3f3-5c82f092b50f.jpg", "turntables/5c60d1d5-93cd-4d1f-bc08-a71b618f8db1.jpg", "turntables/cad89cec-ab83-4c15-a342-4db7febb7b47.jpg", "turntables/f6d65c59-ef8a-48b4-9d8f-25604632a642.jpg", "turntables/a4dcb3b4-cfa8-49a3-aa93-efdc15749e80.jpg", "turntables/57bd29d4-a900-4953-882f-11d32002e527.jpg", "turntables/7bbab53c-6105-4b44-a121-44c3c470ffcf.jpg", "turntables/160c987e-131e-45dd-9893-418d40ef8b02.jpg", "turntables/57d28c6a-4247-41be-9e2b-9b03ef8f18a7.jpg", "turntables/c027ab36-3632-40a3-ae7e-4b3d3818088b.jpg", "turntables/cfff56e2-78d8-4c03-afec-a7236704f85c.jpg", "turntables/1f9794d8-a9da-41fb-ab35-aef4221371f7.jpg", "turntables/c0527cf1-bf7c-4f5a-9326-e03268954b9a.jpg", "turntables/c96ee4cf-5075-4b5d-86ea-fab8d966f798.jpg", "turntables/59bef631-75e6-4bac-b456-843cfb68ebd4.jpg", "turntables/7d7621f8-b969-40f9-b0e4-7518da877506.jpg", "turntables/610699e7-31f5-4ae1-a29b-8bb028626325.jpg", "turntables/c03545f2-7c7a-4766-9a8c-eddb9fd5fa36.jpg", "turntables/bcda3dec-9196-4515-ba8a-8ea162090205.jpg", "turntables/f5fa38f4-283f-46c2-9615-e831b3d4a487.jpg", "turntables/c82c66b4-6680-4278-8991-a6b2dace0530.jpg", "turntables/8d12dc81-efba-4b46-810c-9ae246f86c95.jpg", "turntables/59621e09-1c77-4bc9-8753-e70790f7bb2b.jpg", "turntables/7a0ac792-fd03-4722-928d-fc9cf1f73e47.jpg", "turntables/a91f88f9-c454-4347-bd41-c718b5a3b67e.jpg", "turntables/2372eebc-1f5a-46e0-8104-b7a25780e10c.jpg", "turntables/608d8ba2-50ba-478a-8ca9-6ddb2eccd749.jpg", "turntables/7ff147ef-a8f5-4219-81ab-6c3abfbcc518.jpg", "turntables/c5834b81-060f-4cb3-b27d-86ff97eb1797.jpg", "turntables/35dcd3cd-7072-4802-8e3c-4484988a6014.jpg", "turntables/8cd4a15e-85ff-40c5-88ac-4ac740609c37.jpg", "turntables/dae269ad-d938-4fe6-b17e-8a52dd96264f.jpg", "turntables/7758948c-9288-4720-b474-73e9255673b5.jpg", "turntables/0e8039f6-7b00-4ef8-a5c5-f705073c66d1.jpg", "turntables/5bd49ccf-2e45-4568-8f5f-8b3b8fc448d9.jpg", "turntables/fb7bd382-9aac-49d9-bd77-17cc207003e0.jpg", "turntables/583066d8-f10c-46b2-8212-93bd8bf896a0.jpg", "turntables/abe43b2e-4f19-437d-800b-7e1968f6605a.jpg", "turntables/b094e7a4-652d-4de5-a4bb-ecf998cd13ec.jpg"]', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-11-19 20:23:10.689346+00'),
  (E'ac0a0540-391b-4c47-a56f-75df0d53416d', E'печень', E'["turntables/ca2e4a31-39f5-480c-84c2-adc778d4123c.jpg", "turntables/349bc9fb-4ba1-43a4-aa80-1731987dfa7d.jpg", "turntables/0f260de6-dbe0-4a64-b5c4-e6472aea406e.jpg", "turntables/e973fdb6-b296-4ed7-90dd-39dd1c73c671.jpg", "turntables/e35b69e1-a28f-4a6a-9c56-f7be203617aa.jpg", "turntables/22ca4fee-e796-411b-8ba4-fcdf90c465c5.jpg", "turntables/6cb270a7-74de-44f4-ac31-85f89de3bba8.jpg", "turntables/aac08073-6f4a-4cc7-8d0f-7d6692e2cf2f.jpg", "turntables/5faf6332-2fc5-4575-86d0-475b42d26b25.jpg", "turntables/b61b5beb-c8d2-4f93-b700-3a23cf10e226.jpg", "turntables/c4c14682-5100-40da-abe2-942da523e8fb.jpg", "turntables/95f1acb2-593c-4b15-970f-df966bffeb27.jpg", "turntables/b0bd03f6-cd00-43df-a4ca-10571398c1e8.jpg", "turntables/de64ccc4-b23a-4f52-aab0-ad8bf3dc390a.jpg", "turntables/2839a40f-5c55-4e61-9c27-074340a2e265.jpg", "turntables/214d9249-2285-4316-b41c-8be9face4c95.jpg", "turntables/314ced2c-3763-4999-ba54-d891029290c7.jpg", "turntables/b9e55390-ca83-4323-b6a3-22b207856189.jpg", "turntables/0704906a-2035-4931-bb6e-8094754cf4bf.jpg", "turntables/4bdb0577-162a-482a-ad63-27dcc6b5fc18.jpg", "turntables/fcd9293f-208e-47f3-804c-17718314f18b.jpg", "turntables/9470228b-1502-4b48-a287-bfa6adfc2d3f.jpg", "turntables/d9f3abcd-cb56-45b3-8284-0f4101ecaf91.jpg", "turntables/2272192e-893a-40b8-ac8a-5c19142c0c83.jpg", "turntables/3f519f87-4058-432b-99a1-dda884e3adb0.jpg", "turntables/2aeb465e-fb50-4671-a37e-a111ef592b57.jpg", "turntables/8b24d8ac-decb-4629-ae09-aca1e418ce05.jpg", "turntables/4e536c64-7c3c-4998-8df6-3c4abad3e142.jpg", "turntables/31351264-e56d-49c8-aed1-e9d87cc59cd2.jpg", "turntables/b4a82b87-f338-4d1f-bbd6-d19f7a7c0f22.jpg", "turntables/4761c9a3-f45e-4d22-82d1-9f097da1d316.jpg", "turntables/4935513e-5bbe-4664-b6c8-e32652a3b715.jpg", "turntables/6a69cf41-ec0f-467c-949d-94ed56d6a8c7.jpg", "turntables/a2f5d954-5809-4e6e-8ffd-283c481b7a4e.jpg", "turntables/314e8845-ed4a-4bf1-be80-e38321cb7245.jpg", "turntables/6ff5440e-b53b-4e18-9074-2277667f4590.jpg"]', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-11-19 20:33:06.73726+00'),
  (E'7c2aa764-945c-4f17-8874-c9407aa67a54', E'колит', E'["turntables/5cefab46-0b37-4ccb-ad02-45147870a415.jpg", "turntables/62d7e0eb-83bb-48f3-90f3-57465b16e8dc.jpg", "turntables/76f92988-53be-45cf-8882-b4df4f9fb0ef.jpg", "turntables/a39468b0-a147-4370-a84f-0cbb6706ee49.jpg", "turntables/2c53bde3-641c-48ef-a75e-e0df951c6836.jpg", "turntables/bab2af39-964b-475d-813e-8d822eb119c0.jpg", "turntables/8c1b6eec-5b53-4b16-9710-a97a0c8f1d24.jpg", "turntables/cd704d45-8cd4-4cf9-94f4-bac7693c5e1d.jpg", "turntables/9ed6bd9f-f1e4-4860-9c45-a799ecd22f2a.jpg", "turntables/4419cc73-d894-4b12-8e7a-d012ebf41304.jpg", "turntables/8b4de0ef-545f-450b-b6e0-c5a33d298931.jpg", "turntables/688d6be7-f84a-40d0-840c-9ba0963047fa.jpg", "turntables/de43bbcd-b2b6-4ca0-a6d9-36f31f1cd47a.jpg", "turntables/5534291d-58d6-40a1-b404-2dc79a03c5f8.jpg", "turntables/ed82e2b3-5b1d-44c9-9e0f-804d0f6aa88e.jpg", "turntables/6652240c-eb5f-4ee9-b015-9bcfb44b6c78.jpg", "turntables/68cc5bd5-0c5a-47df-a05e-0dae3dd79241.jpg", "turntables/48c245e2-94a5-408e-955b-a81a61b64bad.jpg", "turntables/c6572ece-d60b-4f3e-b777-7612a2966b5a.jpg", "turntables/6d1b4095-8da5-471e-b907-b7077aed797d.jpg", "turntables/e31a311b-2df7-40a6-9171-a60f1a765c0b.jpg", "turntables/b59f9361-14f8-47f8-953b-d9d3efaac0a4.jpg", "turntables/995bdc03-23d8-4c14-a651-837495c1489c.jpg", "turntables/af5c9c74-b43a-4ecd-8c9a-e016f1bb16f3.jpg", "turntables/a019ebe1-f454-4c69-996c-ce1e2b835a78.jpg", "turntables/f35497cd-7db6-4fba-9009-7f5686abb632.jpg", "turntables/195d35e4-5bfe-4feb-8056-95aa2932bf7b.jpg", "turntables/5b2082e8-34c6-43c3-b8f8-ae8a12b76809.jpg", "turntables/7a06c0bf-8cba-431c-b5b5-98572737d99e.jpg", "turntables/dc8c61ba-cc2f-4bd9-b1e4-4af84915222d.jpg", "turntables/a4289a07-0845-45d2-a099-341cddb0b2cf.jpg", "turntables/44f5636c-5e32-420b-87f6-f550b4051af2.jpg", "turntables/bde9202e-cffc-423e-9d4d-1ecc84adfc92.jpg", "turntables/26a51405-9944-4805-a500-c31fd6332d6e.jpg", "turntables/329f5dae-5fc8-4b29-badc-d264ccbc3d5e.jpg", "turntables/d9b17acd-df10-4bc7-a41f-74e65ebbb118.jpg", "turntables/0e2c8f1c-5eaa-42ab-b068-e459dba27e3d.jpg", "turntables/eda0c1e8-94fd-45ef-a1cd-89b7255ef518.jpg", "turntables/9e83e9aa-9539-4fa4-889d-74b48b5cab8a.jpg", "turntables/e16bb743-ceb1-47b2-9b5d-c8209964a071.jpg", "turntables/c2c74967-1095-4a78-b944-da6a520ce1a5.jpg", "turntables/b39b30a5-970c-4658-9b7f-b6618e0fdd1e.jpg", "turntables/3af3296f-172d-46a4-96c2-68dfc152fbc2.jpg", "turntables/28beaddf-a9b0-4682-b07c-6fd482774280.jpg", "turntables/052ccf2c-1617-4d18-8779-7f60612ac6f7.jpg", "turntables/6e0ec2b1-4746-4c48-9606-6537d15570a4.jpg"]', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-11-20 00:29:15.422581+00'),
  (E'68f4f4ca-412d-44ab-b86b-e3b6d10a4333', E'аппендицит', E'["turntables/b5a48513-9d1a-4505-8734-1d32f6c1096e.jpg", "turntables/40b59682-4c18-4d69-a743-311946da9202.jpg", "turntables/9e6a04bc-c478-43c0-8147-072c0c69485c.jpg", "turntables/e90780e2-bd3e-44bd-a191-d7424591a405.jpg", "turntables/3d95fc26-448f-432b-9184-9b4c080e87ad.jpg", "turntables/5642a2b6-e33a-4b3e-a1fb-33e4b8b5829e.jpg", "turntables/5afccd7a-8b39-4f4e-9b7e-134975640d9c.jpg", "turntables/6a02c9ca-5d6d-4295-b9a2-6f9beb8dcee5.jpg", "turntables/d1343a62-79af-4f6f-a8b5-52541e540f22.jpg", "turntables/37813d0b-76b7-443e-af20-4d9278cb788e.jpg", "turntables/3200a2bb-a965-433d-98f4-4913a13091a9.jpg", "turntables/c489ebe0-ca29-41cf-b490-05485dc73703.jpg", "turntables/142926ed-122e-43fc-9247-51629a2e5a5b.jpg", "turntables/78a10c42-e67d-4aac-be93-729d7356bb61.jpg", "turntables/4fbb4e62-ec35-4294-88d5-9a5c89cba9bc.jpg", "turntables/f9bb5793-7b09-49d6-9d00-056b18aea6dc.jpg", "turntables/5f7312d1-b51a-4855-ae07-aeff11ab0cb3.jpg", "turntables/0ac2b1b7-9a18-4a6e-ba14-f844af25c5d9.jpg", "turntables/8b42f527-289b-4318-bf67-f96440483bbb.jpg", "turntables/98a99d2e-5f9a-411b-a2fc-02e4a6d11b01.jpg", "turntables/77dd0bae-06ec-43f7-b287-1cabd41e4174.jpg", "turntables/4c76761f-1a4d-4aee-ab73-1866ddd1b257.jpg", "turntables/2ff2adc1-80db-4d8e-a0b5-83a0b2597900.jpg", "turntables/6a5da6b9-eb59-4f52-a803-7003f4910134.jpg", "turntables/b7a251b6-f355-4f10-aaa6-fbc705296e22.jpg", "turntables/74be1264-4ad0-4fb0-a822-90b98767309d.jpg", "turntables/4bb55312-394c-49ce-a580-f76783f4899a.jpg", "turntables/63041de8-430c-41e6-8d8f-2a22624e6f5f.jpg", "turntables/a56fbed5-53a5-4968-8c34-54f3390da9a4.jpg", "turntables/dce09b0f-8008-442f-8daf-57d834f065c7.jpg", "turntables/43888461-228c-4a1a-bf30-a6944c41ca96.jpg", "turntables/823ff4a1-327d-4216-8f7f-4169cf33ebad.jpg", "turntables/e2bf122e-afa0-443e-9ca9-4a84988480ef.jpg", "turntables/c25fdb3d-9707-41b3-9827-77fa3eb83dd7.jpg", "turntables/b3649db5-0646-4f6a-a56d-8ce9cf633b70.jpg", "turntables/61d9db2c-24ac-4c61-af09-675c98cc6b1d.jpg", "turntables/4c60bedc-1d4d-420a-8ff0-5d76e83556e0.jpg", "turntables/0a12295e-7bd2-4558-992c-658606a9aa36.jpg", "turntables/34719c58-042f-4227-8a00-a3f00d6d8450.jpg", "turntables/57c8108a-3401-4375-b404-79a70780fb3e.jpg", "turntables/5d11ff8d-4b8d-4eed-ab87-b28cef92e157.jpg", "turntables/85a0033c-86a6-4c57-9276-41333affbed8.jpg", "turntables/cdd49858-7518-406f-90be-df9ac00b1c1b.jpg", "turntables/5e3eabd4-bc6d-4eaa-9944-72ed4a2e94fe.jpg", "turntables/19be5e89-e6b6-4740-89b3-70bbc0972de3.jpg", "turntables/84252e79-2493-48a3-b877-a0a94d04c136.jpg", "turntables/7cafbcdc-e9f9-47eb-93f3-4ede23e25d9c.jpg", "turntables/89ef2f4d-3558-42e1-82b1-6a1229709af4.jpg", "turntables/65fa6fd3-a3ff-479e-9720-5d35b01f7542.jpg", "turntables/23191eb3-07f1-4784-864b-168985a7a207.jpg", "turntables/bb528afd-ee54-497f-9522-26a18a1872d8.jpg", "turntables/cf7ce7a1-5bb2-4bb5-909a-79bfde6c5e96.jpg", "turntables/05740e4c-63cc-477a-b65b-e86c417fffc6.jpg", "turntables/13b427bc-54b9-4c7b-b25b-c6fb1c3451ab.jpg"]', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-11-20 00:37:12.874078+00'),
  (E'426387d4-e6c1-40de-8b96-146233c5086a', E'Кровоизлияние в мозн', E'["turntables/f7f27b2a-712f-4085-8bc8-e88f31fe7438.jpg", "turntables/c7ee9ed4-dde5-46be-abd1-6e9baeb63acd.jpg", "turntables/5fa10258-ebf1-4c6e-8a94-239e12868be6.jpg", "turntables/5ad8b518-6ed8-46a3-9e78-d011c0879da8.jpg", "turntables/fc815de9-73ee-4d2b-b3bf-389abee543d3.jpg", "turntables/ed0777f1-bc3c-475f-930e-ae3751f3d730.jpg", "turntables/c72e1f4d-8cf6-4529-a730-601be62d2e88.jpg", "turntables/a95a493a-885b-4fff-8f09-f327934193e3.jpg", "turntables/79dac0ef-04b4-41c2-b990-59f52ef4b795.jpg", "turntables/a23d100e-2906-4bd5-a7f2-dcd99bc8e849.jpg", "turntables/923d26d8-a915-415c-80d7-49cd9d880a5c.jpg", "turntables/56d9107b-8c0a-450d-911a-0f7c37491c30.jpg", "turntables/df1247ae-4aed-47db-996d-e816fd9d6c33.jpg", "turntables/fca99f09-cb30-492b-a6de-86d72ec1a543.jpg", "turntables/ec0b8b2a-1825-4cba-a479-d650a6aa6414.jpg", "turntables/4a309166-f624-49c0-90ed-08cd300b388f.jpg", "turntables/5724bcb2-5870-4626-9768-26a754dbd1dd.jpg", "turntables/3a6b9ca0-0a9b-4928-bcb2-7fa2e2b1a744.jpg", "turntables/6012f652-c91d-4150-b06f-6af7485e023c.jpg", "turntables/fc171b9d-af8b-489e-b06f-7c264de6e3a8.jpg", "turntables/c58f6a48-00cb-4d0b-88e4-f9eba2cce04f.jpg", "turntables/3c768ce4-efd7-4c57-8d9e-f4096b04e232.jpg", "turntables/7cdb5c04-5c5c-4848-a77a-05cdf342fb13.jpg", "turntables/c226728a-d886-410e-a983-44c7b476906f.jpg", "turntables/e2e424ca-34d1-469f-ab92-968c887dd363.jpg", "turntables/f00ab773-b3e4-4f04-aa41-ee12d37b4ad9.jpg", "turntables/37cb807f-f522-41c7-8969-b3f971a5d444.jpg", "turntables/d589da49-c011-4fc7-b4a0-9f03d4354891.jpg", "turntables/15edb0e2-2ad3-4242-ac1f-d26373a54a00.jpg", "turntables/c19cf5d6-32a8-4ac2-bcc5-6a52def16c51.jpg", "turntables/7894d7ac-47aa-43d2-a9cb-eb95cddc8e8a.jpg", "turntables/b554479d-f5b5-4d51-907d-80bf60a90d0b.jpg", "turntables/6d1de446-6b15-46ed-98a5-c5228d1dc013.jpg", "turntables/bdb385cc-7d1c-4266-88eb-0e2f077f4cfa.jpg", "turntables/da8e9cda-bf67-40b5-851d-cbc4c14b37fa.jpg", "turntables/3ecb40b8-0c65-4b19-99ab-bd6188ed51d7.jpg", "turntables/effa3ce0-d39d-4c37-9098-df5e55d13d2c.jpg", "turntables/67dfcc09-fae0-416f-b79a-7a8d7340b3b5.jpg", "turntables/7237aade-8279-480c-9192-3da9d093f8c8.jpg", "turntables/44bd2b31-46e8-4a76-ba04-d089ba2cb71a.jpg", "turntables/f0eb79a0-08dc-43d9-a8f9-e614495a72cb.jpg", "turntables/5acc0973-c0c8-4993-a1d8-eaca958aa561.jpg", "turntables/0c8c7fc0-0d8b-4657-83ef-fbce97e62bdd.jpg", "turntables/139527dd-a0fa-41c3-9b69-c62acb15019c.jpg", "turntables/f6fcb0bf-2719-4a66-a113-5f45fa9eda3f.jpg", "turntables/33b60364-a8a1-4e41-83eb-b1368cf93818.jpg", "turntables/d7fb02ab-70f1-4ec9-8019-18801299e00c.jpg", "turntables/6aea4c96-8882-4674-9bd0-6dbf72b0b021.jpg", "turntables/ad17869a-c8bd-4ef2-beed-498ebb033263.jpg", "turntables/69f1ccea-3e9c-4069-aa15-b68ba111cd7d.jpg", "turntables/a9f57917-4f60-4630-afde-f55506445811.jpg", "turntables/b034ad02-27e2-463d-945b-238d51e56e3c.jpg", "turntables/c67ab575-dc8e-4fe7-883b-0c788a935b9a.jpg", "turntables/634d67c9-2f22-49b2-bd90-db5e1a8953df.jpg", "turntables/f8addfae-5b1d-4cf7-8cb9-7b08d23fad2d.jpg", "turntables/e9ee0bc2-a19f-4aec-9f91-3e44ec11566b.jpg", "turntables/86824197-65f4-441e-9d6f-8ab5280b1f5d.jpg", "turntables/19f8784a-fec4-4342-87fa-62574e7603dc.jpg", "turntables/0a5e1592-aceb-4d8d-933e-70cd0b54a6bc.jpg", "turntables/53364de3-f181-42e7-bd7e-1ee33bc28592.jpg", "turntables/06db77ba-906b-4239-8af3-31cfd5689374.jpg", "turntables/fc937e1d-d73f-4b49-8399-a89ba934c6cc.jpg", "turntables/86760eeb-8c68-43b9-a356-56c857332392.jpg", "turntables/202f6e4e-0a52-4fc2-8283-1e6a6c04b081.jpg", "turntables/ffda45ed-1633-4abf-ba06-4734eef89621.jpg", "turntables/977ddd46-bbac-4dd3-a48f-ffdbbb6d8305.jpg", "turntables/2229af7b-9afd-49c8-863a-8be3c0d9b3cb.jpg", "turntables/296c79b2-c48a-4bc9-af52-3c6152bf4203.jpg", "turntables/48e2b8c5-f31c-4cdc-b036-e407198b48c6.jpg", "turntables/0a73d904-e9b2-4830-b98f-4ef65f52f534.jpg", "turntables/aeace77a-cfbd-40ab-a4ec-58a9d653d4b7.jpg", "turntables/7c598aa1-74e4-482e-a9f7-d0f243b314bc.jpg", "turntables/cc0a5608-dafa-4963-86ad-5c590fef94af.jpg", "turntables/00748491-9ffe-4504-a904-b10d72ea3045.jpg", "turntables/800ab6e8-bfd8-40ef-87e7-f54dec3490df.jpg", "turntables/3db507bd-c84f-401d-8704-746f9509be17.jpg", "turntables/f059c59e-173e-49d0-a85c-139efabc5cba.jpg"]', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-11-21 20:42:34.8939+00'),
  (E'76246477-3eb7-484b-9e74-5a727bf23646', E'авп', E'["turntables/76246477-3eb7-484b-9e74-5a727bf23646/e6fd1491-54ef-4a8a-9444-5f8df44e3cfe.jpg", "turntables/76246477-3eb7-484b-9e74-5a727bf23646/ea377533-e29d-45f7-9d6d-398574df88d7.jpg"]', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-11-21 21:58:06.567528+00'),
  (E'4efcd4a8-c8e4-488a-955a-2cf97aae40f2', E'Папиллом кожи', E'["turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/ae60e3c0-a64c-497f-bd20-d8ff27be2d73.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/222e288c-26ba-4f95-b1fd-7aaada3d69dd.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/c902cec2-22e4-4478-b6d3-658d3f0f53d8.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/37e7d500-8bf2-4bc1-936b-ec19a6024f27.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/db479981-ad8b-4873-b760-12eef4dd2de8.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/9b75c92d-5779-4c7a-8be4-c7fb1e34ead8.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/ac767d73-160d-44f7-9590-301a7bcc3469.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/9b6b1dbe-8f4b-4dee-bfdc-0bc5601d9d91.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/d183318c-d74f-4410-89c8-ba754ba35cdc.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/2b96e0b5-63cf-4f2f-84ec-6bf6415ffa1b.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/958269e5-49cb-40fb-809e-c63d836e5ecd.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/e508b572-384c-45ca-861f-9a5b0e86b582.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/00d81e31-cb33-4006-89af-afd03a4b4b76.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/f63ec4ce-da62-4c38-b9d3-2a80070275dd.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/577616e6-82b3-42ed-916c-08d20f0d86c9.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/70fa92b8-f10c-4c25-a4f9-2207a39a9b3f.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/20e585f9-f7aa-4eeb-a761-8eb913384861.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/35d1c839-cc0b-4db0-b4bb-88fcf6bc127e.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/86ceeb02-e8f1-42dc-a679-919680d85055.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/3b335b88-74be-4698-81d9-e74d9a7abf6f.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/5f798cc3-6311-492d-a630-a08da51412c5.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/de2c80c4-52f6-40ac-892c-0aea8351d03a.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/291cbf70-4b10-4858-935f-37d1962bc86a.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/6018a295-6fad-47c2-b337-52e622ab9d95.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/242ef49f-7eb1-47de-9d72-a61e795b4135.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/b342c8ad-52be-4b5c-8366-6a05e8c1d6be.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/ad45b0fd-a9d1-4a6a-8ded-625007392068.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/a3ee854a-0a1b-43d2-8ad5-f0f0ddce8773.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/35ceda4e-2215-49be-97f1-e1eefcd93914.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/cfa9646c-563f-4b17-a93d-3e6879589f29.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/b5b64f8c-64e8-49d6-b7a7-1e7c4d65d2ca.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/9c3ca4a6-2e2b-4e27-b914-4b03a2d7636d.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/27ed3b17-f9af-4756-84cd-b2364490d909.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/05c62f55-a1c3-44c7-8b3b-60b1e4ff0dfd.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/ec09037d-41d6-4e66-b2bc-a2a3a8fb27d7.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/27e6fd82-3e82-49f1-8ad7-f8fdb3236155.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/a9b3a6f4-42a2-4a43-b776-2e162c8a7fc9.jpg", "turntables/4efcd4a8-c8e4-488a-955a-2cf97aae40f2/b8bef0ba-64f2-4039-8c13-2c1cfd43a4b3.jpg"]', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-11-21 22:39:22.125305+00'),
  (E'5d0e5d32-e2ac-4717-a802-fea5d41bae26', E'Буллезная эмфизема', E'["turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/ad39be9f-a127-4b93-bb87-7502d4fafe51.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/787d1bc0-42c4-4c73-83fc-68432fda8f0b.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/e8a2704c-07c2-4573-bb8e-398f199bf0e1.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/f0d8a627-36da-46be-84d2-c97e9772691a.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/b354da0c-c5dc-46ef-9168-84cc47186364.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/d0554c4f-cd49-4d68-b44f-0eca8f83d8f2.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/a18067df-7033-4ca7-8444-a25aebce5383.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/1dde782e-e3f7-464f-9f47-6dc77ebb9842.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/22a28213-8598-4d29-9717-f3b5490fb647.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/e423456f-4ab3-4710-919d-3f63b62ba173.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/de235380-f736-4582-8b5b-f9452e8ceff3.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/099bdf9a-5e8c-4c23-a3e5-f5b93477e560.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/0d5adebc-2e3e-4c09-8f47-ebbe584ffe55.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/5a885781-e548-4a04-9150-e8533b1b211a.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/b9134036-8152-48c5-85f2-17a43617140a.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/79a0b9e3-d81e-4ecd-a73f-865bff8bfecb.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/b3859efb-fd49-4d4e-83b5-25a71e11df88.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/2e96d519-3736-497f-8ac6-e5fbf3b64059.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/dd06a35d-0d69-438e-8d90-53c7ef1f1209.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/87cad97e-6ff8-4828-8377-fc0e53dac628.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/5f36de68-17f7-4479-8438-df8718c3bd21.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/6bc703cc-3436-4fb1-b5ab-f5007c65bc6c.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/d15d59a4-3080-4ecf-b589-7f20427105a1.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/bdbc867f-6d12-4149-984b-98fd71e6175c.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/d8379da9-91f2-4643-9ff3-abf5a74a30b2.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/f0bd1846-a8ac-461e-a6e7-308760bd51fc.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/fcc8a92e-62ce-4816-999e-76565c7e859a.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/c0684898-e96b-46ee-a87f-ffb2d669cccb.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/c2c8f1c1-a4a7-437a-9e4a-9eb7626ddf49.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/324bc3bf-0c89-4886-877e-a210c907cae1.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/fe238c96-0f2f-4f5c-8489-a6e8851c090f.jpg", "turntables/5d0e5d32-e2ac-4717-a802-fea5d41bae26/c0ff60ac-e293-461d-8053-a66a349cd318.jpg"]', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-11-21 22:42:48.665592+00'),
  (E'77a75e99-8785-47a0-9832-de1dc5c4087c', E'Аппендицит', E'["turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/274e2281-0eb5-4b81-8de1-5d201773b20f.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/e1df921f-d1c3-4c04-9920-8f98c316660f.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/ee9bb4b2-0f65-4158-bb68-39a229c17e8a.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/74f45a01-78f0-4aea-8f93-95c640034d37.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/647abf26-7fc9-489b-a739-4e6eb6f78794.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/a2f32f67-c76f-44b1-83ca-f7536ef4060e.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/a2be3353-fee0-48ae-aa6f-3737b7affc7a.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/ed543503-e6de-4be8-96ce-bca3b22c4575.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/bf64f09e-0903-437f-8ba9-6cce25f2a077.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/9d9c87f5-4084-441b-83da-03e11e275b59.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/630d9787-ac1c-4562-905b-508aff85a34d.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/58508935-9456-42aa-b753-41fea2822876.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/3afd6a47-0e7c-4546-92f8-84886d0dc132.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/1ab9f4c8-a7f4-41e2-a7b0-da0ac4876976.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/6e191033-2908-453c-bbea-7fee76237829.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/4304fd0b-7587-4606-b226-a290b7b05a85.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/f80dcb59-c5c1-4312-8ea5-2c48dc72d53b.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/babae734-34e8-4544-ab34-2a68c602daef.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/04b9f408-5f16-4f97-98be-77617951b061.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/a7268242-4a1a-42f1-a1c5-5adc5690db66.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/a8d7bef9-14f7-48e1-b5d6-5ecc7827c251.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/9d4ab6fa-a082-4b09-b18b-a60d7595e08f.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/ace29c10-df71-4e93-8938-115f903dd70a.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/67294265-4f3b-4029-8add-8f4a7fad13b4.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/892840bc-8274-45c2-ac1b-8e0c4505e953.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/342cebee-bf55-4fb7-bb55-3c8695c7e5ab.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/8878e28f-619f-4707-815b-b9a5bc883288.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/39407e6b-9b80-4fc9-a91f-1535b2c4c476.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/7c61f8a5-79cb-4d92-86bf-644ba5c761b5.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/da1c0050-a23a-41a4-a436-4790cd2f22ba.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/3072a2f8-4614-44a2-8a67-2cc40d2115cf.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/4517f122-933d-4340-86bc-893158dc446f.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/238198a1-06ba-4500-ba3a-d113600cdf03.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/2b72c5d3-29c5-48ac-a59f-2d5e20246693.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/3bb38188-cd07-48d9-9e8b-c236f8375f8d.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/d317940d-48d6-4788-ae62-eb878ab7c9a8.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/c6e2f3fe-a96e-44e0-9ff1-5ff6363738de.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/5cea5b15-eb77-4d92-81b6-15b31c8440e9.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/d7caf47e-2eca-42ab-8278-1526d33863fc.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/ae16db96-4bda-4162-b3bd-d2e59de4afe9.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/114fe0ec-d718-455c-8720-4bd3d2c8426b.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/45b2987a-935b-4bd0-8fc4-6e57eb898d32.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/8ad77b30-fa56-415a-87a4-c754af7ff51f.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/b74e1989-a0b7-4e7f-bed0-513f2ead3e87.jpg", "turntables/77a75e99-8785-47a0-9832-de1dc5c4087c/58fcc468-0d34-451c-8f26-5621cedc990e.jpg"]', E'cc4ba595-9fae-4ae1-9870-bd927ebd23b2', E'2026-11-21 22:54:19.572091+00');



--
-- Name: attempt_answers_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.attempt_answers_id_seq', 15986, true);


--
-- Name: topics_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.topics_id_seq', 43, true);


--
-- Name: admins admins_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admins
    ADD CONSTRAINT admins_pkey PRIMARY KEY (user_id);


--
-- Name: attempt_answers attempt_answers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attempt_answers
    ADD CONSTRAINT attempt_answers_pkey PRIMARY KEY (id);


--
-- Name: attempt_states attempt_states_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attempt_states
    ADD CONSTRAINT attempt_states_pkey PRIMARY KEY (attempt_id);


--
-- Name: attempts attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attempts
    ADD CONSTRAINT attempts_pkey PRIMARY KEY (id);


--
-- Name: learning_materials learning_materials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.learning_materials
    ADD CONSTRAINT learning_materials_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: question_options options_id_question_uq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.question_options
    ADD CONSTRAINT options_id_question_uq UNIQUE (id, question_id);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_username_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_username_key UNIQUE (username);


--
-- Name: question_answers question_answers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.question_answers
    ADD CONSTRAINT question_answers_pkey PRIMARY KEY (question_id);


--
-- Name: question_comments question_comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.question_comments
    ADD CONSTRAINT question_comments_pkey PRIMARY KEY (id);


--
-- Name: question_favorites question_favorites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.question_favorites
    ADD CONSTRAINT question_favorites_pkey PRIMARY KEY (user_id, question_id);


--
-- Name: question_options question_options_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.question_options
    ADD CONSTRAINT question_options_pkey PRIMARY KEY (id);


--
-- Name: question_trash question_trash_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.question_trash
    ADD CONSTRAINT question_trash_pkey PRIMARY KEY (id);


--
-- Name: questions questions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.questions
    ADD CONSTRAINT questions_pkey PRIMARY KEY (id);


--
-- Name: site_content site_content_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_content
    ADD CONSTRAINT site_content_pkey PRIMARY KEY (key);


--
-- Name: topics topics_block_title_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.topics
    ADD CONSTRAINT topics_block_title_key UNIQUE (block, title);


--
-- Name: topics topics_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.topics
    ADD CONSTRAINT topics_pkey PRIMARY KEY (id);


--
-- Name: turntable_sets turntable_sets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.turntable_sets
    ADD CONSTRAINT turntable_sets_pkey PRIMARY KEY (id);


--
-- Name: attempt_answers_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX attempt_answers_uq ON public.attempt_answers USING btree (attempt_id, question_id);


--
-- Name: attempts_score_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX attempts_score_idx ON public.attempts USING btree (percent DESC, correct_count DESC);


--
-- Name: attempts_user_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX attempts_user_created_idx ON public.attempts USING btree (user_id, created_at DESC);


--
-- Name: notifications_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notifications_created_idx ON public.notifications USING btree (created_at DESC);


--
-- Name: question_comments_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX question_comments_created_at_idx ON public.question_comments USING btree (created_at DESC);


--
-- Name: question_favorites_user_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX question_favorites_user_created_idx ON public.question_favorites USING btree (user_id, created_at DESC);


--
-- Name: questions_published_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX questions_published_idx ON public.questions USING btree (section, block, is_published);


--
-- Name: question_answers answer_option_check_trg; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER answer_option_check_trg BEFORE INSERT OR UPDATE ON public.question_answers FOR EACH ROW EXECUTE FUNCTION public.answer_option_check();


--
-- Name: questions questions_guard_trg; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER questions_guard_trg BEFORE INSERT OR UPDATE ON public.questions FOR EACH ROW EXECUTE FUNCTION public.questions_guard();


--
-- Name: admins admins_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--



--
-- Name: attempt_answers attempt_answers_attempt_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attempt_answers
    ADD CONSTRAINT attempt_answers_attempt_id_fkey FOREIGN KEY (attempt_id) REFERENCES public.attempts(id) ON DELETE CASCADE;


--
-- Name: attempt_answers attempt_answers_chosen_option_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attempt_answers
    ADD CONSTRAINT attempt_answers_chosen_option_id_fkey FOREIGN KEY (chosen_option_id) REFERENCES public.question_options(id) ON DELETE SET NULL;


--
-- Name: attempt_answers attempt_answers_question_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attempt_answers
    ADD CONSTRAINT attempt_answers_question_id_fkey FOREIGN KEY (question_id) REFERENCES public.questions(id) ON DELETE CASCADE;


--
-- Name: attempt_states attempt_states_attempt_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attempt_states
    ADD CONSTRAINT attempt_states_attempt_id_fkey FOREIGN KEY (attempt_id) REFERENCES public.attempts(id) ON DELETE CASCADE;


--
-- Name: attempt_states attempt_states_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--



--
-- Name: attempts attempts_topic_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attempts
    ADD CONSTRAINT attempts_topic_id_fkey FOREIGN KEY (topic_id) REFERENCES public.topics(id) ON DELETE SET NULL;


--
-- Name: attempts attempts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--



--
-- Name: learning_materials learning_materials_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--



--
-- Name: notifications notifications_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--



--
-- Name: profiles profiles_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--



--
-- Name: question_answers question_answers_correct_option_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.question_answers
    ADD CONSTRAINT question_answers_correct_option_id_fkey FOREIGN KEY (correct_option_id) REFERENCES public.question_options(id) ON DELETE CASCADE;


--
-- Name: question_answers question_answers_question_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.question_answers
    ADD CONSTRAINT question_answers_question_id_fkey FOREIGN KEY (question_id) REFERENCES public.questions(id) ON DELETE CASCADE;


--
-- Name: question_comments question_comments_question_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.question_comments
    ADD CONSTRAINT question_comments_question_id_fkey FOREIGN KEY (question_id) REFERENCES public.questions(id) ON DELETE CASCADE;


--
-- Name: question_comments question_comments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--



--
-- Name: question_favorites question_favorites_question_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.question_favorites
    ADD CONSTRAINT question_favorites_question_id_fkey FOREIGN KEY (question_id) REFERENCES public.questions(id) ON DELETE CASCADE;


--
-- Name: question_favorites question_favorites_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--



--
-- Name: question_options question_options_question_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.question_options
    ADD CONSTRAINT question_options_question_id_fkey FOREIGN KEY (question_id) REFERENCES public.questions(id) ON DELETE CASCADE;


--
-- Name: questions questions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--



--
-- Name: questions questions_topic_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.questions
    ADD CONSTRAINT questions_topic_id_fkey FOREIGN KEY (topic_id) REFERENCES public.topics(id) ON DELETE SET NULL;


--
-- Name: site_content site_content_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--



--
-- Name: turntable_sets turntable_sets_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--



--
-- Name: question_trash Admins can delete question trash; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can delete question trash" ON public.question_trash FOR DELETE TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.admins a
  WHERE (a.user_id = auth.uid()))));


--
-- Name: question_trash Admins can insert question trash; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can insert question trash" ON public.question_trash FOR INSERT TO authenticated WITH CHECK ((EXISTS ( SELECT 1
   FROM public.admins a
  WHERE (a.user_id = auth.uid()))));


--
-- Name: question_trash Admins can read question trash; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Admins can read question trash" ON public.question_trash FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.admins a
  WHERE (a.user_id = auth.uid()))));


--
-- Name: notifications admin manage notifications; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin manage notifications" ON public.notifications TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: question_options admin manage options; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin manage options" ON public.question_options USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: questions admin manage questions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin manage questions" ON public.questions USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: topics admin manage topics; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin manage topics" ON public.topics USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: turntable_sets admin manage turntables; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin manage turntables" ON public.turntable_sets TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: question_answers admin only answers; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admin only answers" ON public.question_answers USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: admins; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.admins ENABLE ROW LEVEL SECURITY;

--
-- Name: learning_materials admins manage materials; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admins manage materials" ON public.learning_materials TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: site_content admins manage site content; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admins manage site content" ON public.site_content TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: admins admins self not readable; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "admins self not readable" ON public.admins FOR SELECT USING ((user_id = auth.uid()));


--
-- Name: attempt_answers attempt answers function only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "attempt answers function only" ON public.attempt_answers FOR INSERT WITH CHECK (false);


--
-- Name: attempt_answers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.attempt_answers ENABLE ROW LEVEL SECURITY;

--
-- Name: attempt_states; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.attempt_states ENABLE ROW LEVEL SECURITY;

--
-- Name: attempts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.attempts ENABLE ROW LEVEL SECURITY;

--
-- Name: attempts attempts submitted via function only; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "attempts submitted via function only" ON public.attempts FOR INSERT WITH CHECK (false);


--
-- Name: learning_materials; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.learning_materials ENABLE ROW LEVEL SECURITY;

--
-- Name: notifications; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

--
-- Name: notifications notifications readable by all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "notifications readable by all" ON public.notifications FOR SELECT TO authenticated, anonymous USING (true);


--
-- Name: question_options options readable; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "options readable" ON public.question_options FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.questions q
  WHERE ((q.id = question_options.question_id) AND ((q.is_published = true) OR public.is_admin())))));


--
-- Name: attempt_answers own attempt answers readable; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "own attempt answers readable" ON public.attempt_answers FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.attempts a
  WHERE ((a.id = attempt_answers.attempt_id) AND ((a.user_id = auth.uid()) OR public.is_admin())))));


--
-- Name: attempts own attempts readable; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "own attempts readable" ON public.attempts FOR SELECT USING (((user_id = auth.uid()) OR public.is_admin()));


--
-- Name: profiles profile update own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "profile update own" ON public.profiles FOR UPDATE USING ((id = auth.uid())) WITH CHECK ((id = auth.uid()));


--
-- Name: profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: profiles profiles own or admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "profiles own or admin" ON public.profiles FOR SELECT USING (((id = auth.uid()) OR public.is_admin()));


--
-- Name: learning_materials published materials readable; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "published materials readable" ON public.learning_materials FOR SELECT TO authenticated, anonymous USING ((is_published OR public.is_admin()));


--
-- Name: questions published questions readable; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "published questions readable" ON public.questions FOR SELECT USING (((is_published = true) OR public.is_admin()));


--
-- Name: turntable_sets published turntables readable; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "published turntables readable" ON public.turntable_sets FOR SELECT USING (true);


--
-- Name: question_answers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.question_answers ENABLE ROW LEVEL SECURITY;

--
-- Name: question_comments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.question_comments ENABLE ROW LEVEL SECURITY;

--
-- Name: question_comments question_comments_delete_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY question_comments_delete_admin ON public.question_comments FOR DELETE TO authenticated USING (public.is_admin());


--
-- Name: question_comments question_comments_insert_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY question_comments_insert_own ON public.question_comments FOR INSERT TO authenticated WITH CHECK ((auth.uid() = user_id));


--
-- Name: question_comments question_comments_select_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY question_comments_select_admin ON public.question_comments FOR SELECT TO authenticated USING (public.is_admin());


--
-- Name: question_favorites; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.question_favorites ENABLE ROW LEVEL SECURITY;

--
-- Name: question_options; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.question_options ENABLE ROW LEVEL SECURITY;

--
-- Name: question_trash; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.question_trash ENABLE ROW LEVEL SECURITY;

--
-- Name: questions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.questions ENABLE ROW LEVEL SECURITY;

--
-- Name: site_content site content readable; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "site content readable" ON public.site_content FOR SELECT TO authenticated, anonymous USING (true);


--
-- Name: site_content; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.site_content ENABLE ROW LEVEL SECURITY;

--
-- Name: topics; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.topics ENABLE ROW LEVEL SECURITY;

--
-- Name: topics topics readable; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "topics readable" ON public.topics FOR SELECT USING (true);


--
-- Name: turntable_sets; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.turntable_sets ENABLE ROW LEVEL SECURITY;

--
-- Name: question_favorites users manage own favorites; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "users manage own favorites" ON public.question_favorites TO authenticated USING ((user_id = auth.uid())) WITH CHECK ((user_id = auth.uid()));


--
-- PostgreSQL database dump complete
--




-- -----------------------------------------------------------------------------
-- Neon-specific identity bridge.
-- Old Supabase UUIDs are retained in the imported data until each user signs up
-- in Neon Auth using the same login@domain email. The RPC then atomically changes
-- all owned rows to the new Neon Auth UUID and preserves attempts/admin rights.
-- Password hashes from Supabase are intentionally NOT imported.
-- -----------------------------------------------------------------------------
CREATE TABLE public.legacy_user_map (
  legacy_user_id uuid PRIMARY KEY,
  email text NOT NULL UNIQUE,
  neon_user_id uuid UNIQUE,
  claimed_at timestamptz
);

INSERT INTO public.legacy_user_map (legacy_user_id, email) VALUES
  ('53b13ae4-b411-4c8d-8ff3-b23d2ad08a54'::uuid, 'dyuminvad@testpatan-vgmu.com'),
  ('9c46b562-06a3-4efb-ad63-65266e3366aa'::uuid, 'vitad@testpatan-vgmu.com'),
  ('8fbe9c9f-d5f0-4c0f-adc4-a702bb5111c1'::uuid, 'stukalovaul@testpatan-vgmu.com'),
  ('385a14c1-9d29-4018-b334-213bde15d199'::uuid, 'daiasay@testpatan-vgmu.com'),
  ('78fa4aca-f030-4ed9-983d-f7a4a39b54bb'::uuid, '240799@testpatan-vgmu.com'),
  ('cc4ba595-9fae-4ae1-9870-bd927ebd23b2'::uuid, 'dyuminvad1@testpatan-vgmu.com');

ALTER TABLE public.legacy_user_map ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.legacy_user_map FROM PUBLIC;
REVOKE ALL ON TABLE public.legacy_user_map FROM anonymous;
REVOKE ALL ON TABLE public.legacy_user_map FROM authenticated;

CREATE OR REPLACE FUNCTION public.claim_legacy_account()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_new_user uuid := auth.uid();
  v_email text;
  v_old_user uuid;
  v_claimed uuid;
BEGIN
  IF v_new_user IS NULL THEN
    RAISE EXCEPTION 'Необходима авторизация';
  END IF;

  SELECT lower(u.email)
    INTO v_email
    FROM neon_auth."user" AS u
   WHERE u.id::text = v_new_user::text;

  IF v_email IS NULL THEN
    RAISE EXCEPTION 'Не удалось определить email текущей учётной записи Neon';
  END IF;

  SELECT m.legacy_user_id, m.neon_user_id
    INTO v_old_user, v_claimed
    FROM public.legacy_user_map AS m
   WHERE lower(m.email) = v_email
   FOR UPDATE;

  IF v_old_user IS NULL THEN
    RETURN jsonb_build_object('linked', false, 'reason', 'no_legacy_account');
  END IF;

  IF v_claimed IS NOT NULL AND v_claimed <> v_new_user THEN
    RAISE EXCEPTION 'Эта старая учётная запись уже связана с другим аккаунтом';
  END IF;

  IF v_claimed = v_new_user THEN
    RETURN jsonb_build_object('linked', true, 'already_linked', true);
  END IF;

  IF EXISTS (SELECT 1 FROM public.profiles WHERE id = v_new_user) THEN
    RAISE EXCEPTION 'Профиль с новым UUID уже существует; автоматическое объединение остановлено';
  END IF;

  UPDATE public.profiles
     SET id = v_new_user,
         avatar_url = CASE
           WHEN avatar_url IS NULL THEN NULL
           ELSE replace(avatar_url, 'avatars/' || v_old_user::text || '/', 'avatars/' || v_new_user::text || '/')
         END
   WHERE id = v_old_user;
  UPDATE public.admins SET user_id = v_new_user WHERE user_id = v_old_user;
  UPDATE public.attempt_states SET user_id = v_new_user WHERE user_id = v_old_user;
  UPDATE public.attempts SET user_id = v_new_user WHERE user_id = v_old_user;
  UPDATE public.learning_materials SET created_by = v_new_user WHERE created_by = v_old_user;
  UPDATE public.notifications SET created_by = v_new_user WHERE created_by = v_old_user;
  UPDATE public.question_comments SET user_id = v_new_user WHERE user_id = v_old_user;
  UPDATE public.question_favorites SET user_id = v_new_user WHERE user_id = v_old_user;
  UPDATE public.question_trash SET deleted_by = v_new_user WHERE deleted_by = v_old_user;
  UPDATE public.questions SET created_by = v_new_user WHERE created_by = v_old_user;
  UPDATE public.site_content SET updated_by = v_new_user WHERE updated_by = v_old_user;
  UPDATE public.turntable_sets SET created_by = v_new_user WHERE created_by = v_old_user;

  UPDATE public.legacy_user_map
     SET neon_user_id = v_new_user, claimed_at = now()
   WHERE legacy_user_id = v_old_user;

  RETURN jsonb_build_object('linked', true, 'legacy_user_id', v_old_user);
END;
$$;

REVOKE ALL ON FUNCTION public.claim_legacy_account() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_legacy_account() TO authenticated;

-- Data API permissions. RLS policies in this dump remain the row-level gate.
GRANT USAGE ON SCHEMA public TO anonymous, authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO anonymous;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

-- Explicitly keep answer-key data inaccessible to guest and ordinary users.
REVOKE ALL ON TABLE public.question_answers FROM anonymous;
REVOKE ALL ON TABLE public.question_answers FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.question_answers TO authenticated;
