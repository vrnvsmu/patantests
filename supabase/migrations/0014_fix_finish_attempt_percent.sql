-- Исправляет подсчёт результата завершённой попытки.
-- Использует сохранённый флаг is_correct, который выставляет public.check_answer().
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
  v_percent numeric := 0;
begin
  select status, question_count
    into v_status, v_total
  from public.attempts
  where id = p_attempt and user_id = v_user
  for update;

  if v_status is null then raise exception 'Попытка не найдена'; end if;

  if v_status = 'finished' then
    return (select jsonb_build_object('attempt_id', id, 'question_count', question_count,
      'correct_count', correct_count, 'percent', percent)
      from public.attempts where id = p_attempt and user_id = v_user);
  end if;

  select count(*) filter (where chosen_option_id is not null)::integer,
         count(*) filter (where chosen_option_id is not null and is_correct is true)::integer
    into v_answered, v_correct
  from public.attempt_answers
  where attempt_id = p_attempt;

  v_percent := case when coalesce(v_total,0) > 0
                    then round(100.0 * coalesce(v_correct,0) / v_total, 2)
                    else 0 end;

  update public.attempts
  set status = 'finished',
      finished_at = now(),
      correct_count = coalesce(v_correct, 0),
      percent = v_percent,
      duration_seconds = extract(epoch from now() - created_at)::integer
  where id = p_attempt and user_id = v_user;

  return (select jsonb_build_object('attempt_id', id, 'question_count', question_count,
      'correct_count', correct_count, 'percent', percent, 'answered_count', v_answered)
    from public.attempts where id = p_attempt and user_id = v_user);
end;
$function$;
