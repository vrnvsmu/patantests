-- 0016_admin_question_statistics_include_unfinished.sql
-- В статистику администратора включаются сохранённые ответы сразу,
-- в том числе из попыток со статусом in_progress.
-- Для пользователя/вопроса/режима учитывается первый сохранённый ответ.
BEGIN;

DROP FUNCTION IF EXISTS public.admin_question_statistics();

CREATE FUNCTION public.admin_question_statistics()
RETURNS TABLE(
  mode text,
  topic_id bigint,
  topic_title text,
  question_id uuid,
  prompt text,
  image_path text,
  total_answers bigint,
  correct_count bigint,
  correct_rate numeric,
  option_id uuid,
  option_text text,
  is_correct boolean,
  selected_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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

REVOKE ALL ON FUNCTION public.admin_question_statistics() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_question_statistics() TO authenticated;

COMMIT;
