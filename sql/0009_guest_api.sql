-- TestPatan guest access API: session-bound attempts and narrowly scoped read functions.
-- Run this only in Neon branch "test" after taking a schema snapshot. No S3 changes.
-- Requires privileges to install pgcrypto in schema extensions.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

ALTER TABLE public.attempts ADD COLUMN IF NOT EXISTS guest_session_hash text;
CREATE INDEX IF NOT EXISTS attempts_guest_session_hash_idx ON public.attempts(guest_session_hash)
  WHERE user_id IS NULL AND guest_session_hash IS NOT NULL;

CREATE OR REPLACE FUNCTION public.start_guest_attempt(p_mode text,p_topic_id bigint,p_count integer,p_guest_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE v_hash text; v_ids uuid[]; v_attempt uuid;
BEGIN
  IF p_guest_token IS NULL OR length(p_guest_token)<32 OR length(p_guest_token)>128 THEN RAISE EXCEPTION 'Некорректная гостевая сессия'; END IF;
  v_hash:=encode(digest(p_guest_token,'sha256'),'hex');
  IF p_mode NOT IN ('macro','micro','theory','exam') THEN RAISE EXCEPTION 'Неверный режим'; END IF;
  IF p_topic_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.topics WHERE id=p_topic_id) THEN RAISE EXCEPTION 'Тема не найдена'; END IF;
  IF p_topic_id IS NOT NULL AND EXISTS(SELECT 1 FROM public.topics t WHERE t.id=p_topic_id AND
    (t.is_locked OR CASE p_mode WHEN 'macro' THEN t.is_locked_macro WHEN 'micro' THEN t.is_locked_micro WHEN 'theory' THEN t.is_locked_theory ELSE false END))
    THEN RAISE EXCEPTION 'Эта тема временно закрыта в выбранном режиме'; END IF;
  p_count:=least(greatest(coalesce(p_count,10),1),100000);
  DELETE FROM public.attempts WHERE user_id IS NULL AND guest_session_hash=v_hash AND status='in_progress' AND created_at<now()-interval '1 day';
  IF (SELECT count(*) FROM public.attempts WHERE user_id IS NULL AND guest_session_hash=v_hash AND created_at>now()-interval '1 hour')>=30
    THEN RAISE EXCEPTION 'Слишком много попыток за час, попробуйте позже'; END IF;
  WITH candidates AS (
    SELECT q.id,coalesce(q.image_path,q.id::text) group_key FROM public.questions q
    WHERE q.is_published AND ((p_mode='exam' AND q.section='macro' AND q.is_exam) OR (p_mode<>'exam' AND q.section=p_mode))
      AND (p_topic_id IS NULL OR q.topic_id=p_topic_id)
      AND EXISTS(SELECT 1 FROM public.question_answers a WHERE a.question_id=q.id)
  ), groups AS (SELECT group_key,count(*) n,random() r FROM candidates GROUP BY group_key), selected AS (
    SELECT group_key FROM (SELECT group_key,n,sum(n) OVER(ORDER BY r) cumulative FROM groups) g WHERE cumulative-n<p_count
  ) SELECT array_agg(c.id) INTO v_ids FROM candidates c JOIN selected s USING(group_key);
  IF v_ids IS NULL THEN RAISE EXCEPTION 'Нет доступных вопросов'; END IF;
  INSERT INTO public.attempts(user_id,mode,topic_id,question_count,guest_session_hash)
  VALUES(NULL,p_mode,p_topic_id,array_length(v_ids,1),v_hash) RETURNING id INTO v_attempt;
  INSERT INTO public.attempt_answers(attempt_id,question_id) SELECT v_attempt,unnest(v_ids);
  RETURN jsonb_build_object('attempt_id',v_attempt,'questions',(SELECT jsonb_agg(jsonb_build_object('id',q.id,'prompt',q.prompt,'image_path',q.image_path,'created_at',q.created_at,
    'options',(SELECT jsonb_agg(jsonb_build_object('id',o.id,'text',o.option_text) ORDER BY o.sort_order) FROM public.question_options o WHERE o.question_id=q.id)) ORDER BY q.image_path NULLS LAST,q.created_at)
    FROM public.questions q WHERE q.id=ANY(v_ids)));
END $$;

CREATE OR REPLACE FUNCTION public.check_guest_answer(p_attempt uuid,p_question uuid,p_option uuid,p_guest_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE v_hash text; v_key uuid; v_expl text; v_ok boolean;
BEGIN
  IF p_guest_token IS NULL OR length(p_guest_token)<32 OR length(p_guest_token)>128 THEN RAISE EXCEPTION 'Некорректная гостевая сессия'; END IF;
  v_hash:=encode(digest(p_guest_token,'sha256'),'hex');
  IF NOT EXISTS(SELECT 1 FROM public.attempts WHERE id=p_attempt AND user_id IS NULL AND guest_session_hash=v_hash AND status='in_progress') THEN RAISE EXCEPTION 'Попытка не найдена или завершена'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.question_options WHERE id=p_option AND question_id=p_question) THEN RAISE EXCEPTION 'Неверный вариант ответа'; END IF;
  SELECT correct_option_id,explanation INTO v_key,v_expl FROM public.question_answers WHERE question_id=p_question;
  v_ok:=v_key=p_option;
  UPDATE public.attempt_answers SET chosen_option_id=p_option,is_correct=v_ok,answered_at=now() WHERE attempt_id=p_attempt AND question_id=p_question AND answered_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Вопрос не входит в попытку или уже отвечен'; END IF;
  RETURN jsonb_build_object('recorded',true,'is_correct',v_ok,'correct_option_id',v_key,'explanation',v_expl);
END $$;

CREATE OR REPLACE FUNCTION public.finish_guest_attempt(p_attempt uuid,p_guest_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE v_hash text; v_total integer; v_correct integer; v_answered integer;
BEGIN
  IF p_guest_token IS NULL OR length(p_guest_token)<32 OR length(p_guest_token)>128 THEN RAISE EXCEPTION 'Некорректная гостевая сессия'; END IF;
  v_hash:=encode(digest(p_guest_token,'sha256'),'hex');
  SELECT question_count INTO v_total FROM public.attempts WHERE id=p_attempt AND user_id IS NULL AND guest_session_hash=v_hash FOR UPDATE;
  IF v_total IS NULL THEN RAISE EXCEPTION 'Попытка не найдена'; END IF;
  SELECT count(*) FILTER(WHERE chosen_option_id IS NOT NULL)::integer,count(*) FILTER(WHERE chosen_option_id IS NOT NULL AND is_correct)::integer INTO v_answered,v_correct FROM public.attempt_answers WHERE attempt_id=p_attempt;
  UPDATE public.attempts SET status='finished',finished_at=coalesce(finished_at,now()),correct_count=coalesce(v_correct,0),duration_seconds=coalesce(duration_seconds,extract(epoch FROM now()-created_at)::integer)
    WHERE id=p_attempt AND user_id IS NULL AND guest_session_hash=v_hash;
  RETURN (SELECT jsonb_build_object('attempt_id',id,'status',status,'question_count',question_count,'answered_count',v_answered,'correct_count',correct_count,'percent',percent,'duration_seconds',duration_seconds)
    FROM public.attempts WHERE id=p_attempt AND user_id IS NULL AND guest_session_hash=v_hash);
END $$;

CREATE OR REPLACE FUNCTION public.get_guest_attempt_review(p_attempt uuid,p_guest_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE v_hash text;
BEGIN
  IF p_guest_token IS NULL OR length(p_guest_token)<32 OR length(p_guest_token)>128 THEN RAISE EXCEPTION 'Некорректная гостевая сессия'; END IF;
  v_hash:=encode(digest(p_guest_token,'sha256'),'hex');
  IF NOT EXISTS(SELECT 1 FROM public.attempts WHERE id=p_attempt AND user_id IS NULL AND guest_session_hash=v_hash AND status='finished') THEN RAISE EXCEPTION 'Разбор доступен только после завершения вашей попытки'; END IF;
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('question_id',q.id,'prompt',q.prompt,'image_path',q.image_path,'chosen_option_id',aa.chosen_option_id,'is_correct',coalesce(aa.is_correct,false),'correct_option_id',k.correct_option_id,'explanation',k.explanation)),'[]'::jsonb)
    FROM public.attempt_answers aa JOIN public.questions q ON q.id=aa.question_id LEFT JOIN public.question_answers k ON k.question_id=q.id WHERE aa.attempt_id=p_attempt);
END $$;

CREATE OR REPLACE FUNCTION public.resume_guest_attempt(p_attempt uuid,p_guest_token text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
DECLARE v_hash text; v_changed integer;
BEGIN
  IF p_guest_token IS NULL OR length(p_guest_token)<32 OR length(p_guest_token)>128 THEN RAISE EXCEPTION 'Некорректная гостевая сессия'; END IF;
  v_hash:=encode(digest(p_guest_token,'sha256'),'hex');
  UPDATE public.attempts SET status='in_progress',finished_at=NULL WHERE id=p_attempt AND user_id IS NULL AND guest_session_hash=v_hash AND status='finished'
    AND (SELECT count(*) FROM public.attempt_answers aa WHERE aa.attempt_id=p_attempt AND aa.chosen_option_id IS NOT NULL)<question_count;
  GET DIAGNOSTICS v_changed=ROW_COUNT; RETURN v_changed=1;
END $$;

CREATE OR REPLACE FUNCTION public.guest_topics()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
  SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.sort_order,t.title),'[]'::jsonb) FROM public.topics t
$$;

CREATE OR REPLACE FUNCTION public.guest_question_topics(p_question_ids uuid[])
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object('id',q.id,'topic_id',q.topic_id)),'[]'::jsonb)
  FROM public.questions q WHERE q.id=ANY(coalesce(p_question_ids,'{}'::uuid[])) AND q.is_published
$$;

CREATE OR REPLACE FUNCTION public.guest_public_content(p_table text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
BEGIN
  IF p_table='site_content' THEN RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('key',key,'value',value)),'[]'::jsonb) FROM public.site_content);
  ELSIF p_table='notifications' THEN RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'title',title,'body',body,'created_at',created_at) ORDER BY created_at DESC),'[]'::jsonb) FROM (SELECT id,title,body,created_at FROM public.notifications ORDER BY created_at DESC LIMIT 30) n);
  ELSIF p_table='learning_materials' THEN RETURN (SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY m.sort_order,m.created_at DESC),'[]'::jsonb) FROM public.learning_materials m WHERE m.is_published);
  END IF;
  RAISE EXCEPTION 'Таблица недоступна для гостя';
END $$;

CREATE OR REPLACE FUNCTION public.guest_turntable(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
SELECT coalesce((SELECT jsonb_build_object('id',id,'title',title,'frame_paths',frame_paths) FROM public.turntable_sets WHERE id=p_id),'null'::jsonb)
$$;

CREATE OR REPLACE FUNCTION public.guest_question_options(p_question_ids uuid[])
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
SELECT coalesce(jsonb_agg(jsonb_build_object('id',o.id,'question_id',o.question_id,'option_text',o.option_text) ORDER BY o.question_id,o.sort_order),'[]'::jsonb)
FROM public.question_options o JOIN public.questions q ON q.id=o.question_id WHERE o.question_id=ANY(coalesce(p_question_ids,'{}'::uuid[])) AND q.is_published
$$;

-- Compute's server-side database owner executes these. Never grant the functions to client roles.
REVOKE ALL ON FUNCTION public.start_guest_attempt(text,bigint,integer,text) FROM PUBLIC,anonymous,authenticated;
REVOKE ALL ON FUNCTION public.check_guest_answer(uuid,uuid,uuid,text) FROM PUBLIC,anonymous,authenticated;
REVOKE ALL ON FUNCTION public.finish_guest_attempt(uuid,text) FROM PUBLIC,anonymous,authenticated;
REVOKE ALL ON FUNCTION public.get_guest_attempt_review(uuid,text) FROM PUBLIC,anonymous,authenticated;
REVOKE ALL ON FUNCTION public.resume_guest_attempt(uuid,text) FROM PUBLIC,anonymous,authenticated;
REVOKE ALL ON FUNCTION public.guest_public_content(text) FROM PUBLIC,anonymous,authenticated;
REVOKE ALL ON FUNCTION public.guest_topics() FROM PUBLIC,anonymous,authenticated;
REVOKE ALL ON FUNCTION public.guest_question_topics(uuid[]) FROM PUBLIC,anonymous,authenticated;
REVOKE ALL ON FUNCTION public.guest_turntable(uuid) FROM PUBLIC,anonymous,authenticated;
REVOKE ALL ON FUNCTION public.guest_question_options(uuid[]) FROM PUBLIC,anonymous,authenticated;

-- Avoid direct reads of private tables by the anonymous Data API role. Public guest reads use the allowlisted handler.
REVOKE ALL ON TABLE public.topics,public.questions,public.question_options,public.question_answers,public.attempts,public.attempt_answers,public.attempt_states,public.profiles,public.admins,public.question_favorites,public.learning_materials,public.notifications,public.site_content,public.turntable_sets,public.question_comments,public.question_trash FROM anonymous;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anonymous;
REVOKE ALL ON TABLE public.legacy_user_map FROM anonymous;

-- Expect false.
SELECT has_table_privilege('anonymous','public.attempts','SELECT') AS anon_can_select_attempts;
