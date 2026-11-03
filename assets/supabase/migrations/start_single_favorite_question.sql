-- Создаёт обычную попытку из одного выбранного вопроса из избранного.
-- Применить в Supabase SQL Editor после существующих миграций 0005 и 0007.
begin;
create or replace function public.start_single_question_attempt(p_question_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
revoke all on function public.start_single_question_attempt(uuid) from public, anon;
grant execute on function public.start_single_question_attempt(uuid) to authenticated;
commit;
