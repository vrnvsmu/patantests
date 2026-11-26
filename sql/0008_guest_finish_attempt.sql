-- TestPatan: allow the existing finish_attempt RPC to finish anonymous attempts.
-- Run this once in the Neon SQL Editor on branch "test".
CREATE OR REPLACE FUNCTION public.finish_attempt(p_attempt uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_status text;
  v_total integer;
  v_correct integer := 0;
  v_answered integer := 0;
BEGIN
  -- IS NOT DISTINCT FROM is deliberately NULL-safe:
  -- authenticated users can finish their own attempts, guests can finish user_id IS NULL attempts.
  SELECT status, question_count
    INTO v_status, v_total
    FROM public.attempts
   WHERE id = p_attempt
     AND user_id IS NOT DISTINCT FROM v_user
   FOR UPDATE;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Попытка не найдена';
  END IF;

  SELECT count(*) FILTER (WHERE chosen_option_id IS NOT NULL)::integer,
         count(*) FILTER (WHERE chosen_option_id IS NOT NULL AND is_correct IS TRUE)::integer
    INTO v_answered, v_correct
    FROM public.attempt_answers
   WHERE attempt_id = p_attempt;

  UPDATE public.attempts
     SET status = 'finished',
         finished_at = coalesce(finished_at, now()),
         correct_count = coalesce(v_correct, 0),
         duration_seconds = coalesce(
           duration_seconds,
           extract(epoch FROM now() - (SELECT created_at FROM public.attempts WHERE id = p_attempt))::integer
         )
   WHERE id = p_attempt
     AND user_id IS NOT DISTINCT FROM v_user;

  RETURN (
    SELECT jsonb_build_object(
      'attempt_id', id,
      'status', status,
      'question_count', question_count,
      'answered_count', v_answered,
      'correct_count', correct_count,
      'percent', percent,
      'duration_seconds', duration_seconds
    )
      FROM public.attempts
     WHERE id = p_attempt
       AND user_id IS NOT DISTINCT FROM v_user
  );
END;
$$;
