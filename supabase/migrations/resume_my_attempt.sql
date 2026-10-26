-- Позволяет владельцу возобновить частично отвеченную попытку, даже если
-- интерфейс ранее пометил её завершённой после перехода к последнему вопросу.
-- Не даёт повторно открыть полностью отвеченную попытку или чужую попытку.
create or replace function public.resume_my_attempt(p_attempt uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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

revoke all on function public.resume_my_attempt(uuid) from public, anon;
grant execute on function public.resume_my_attempt(uuid) to authenticated;
