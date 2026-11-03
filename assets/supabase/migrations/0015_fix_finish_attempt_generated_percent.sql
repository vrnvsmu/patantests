-- percent is a generated column in this database, so it must not be assigned directly.
-- Its value is recalculated automatically when correct_count changes.
CREATE OR REPLACE FUNCTION public.finish_attempt(p_attempt uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
$function$;
