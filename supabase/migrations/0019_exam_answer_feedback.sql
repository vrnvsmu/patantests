-- 0019_exam_answer_feedback.sql
-- Возвращает правильность ответа, ID правильного варианта и пояснение при прохождении экзамена.
begin;

create or replace function public.check_answer(p_attempt uuid, p_question uuid, p_option uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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

revoke all on function public.check_answer(uuid, uuid, uuid) from public;
grant execute on function public.check_answer(uuid, uuid, uuid) to anon, authenticated;

commit;
