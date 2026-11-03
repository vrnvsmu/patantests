-- Recalculate attempt scores from the selected options, not potentially stale is_correct flags.
-- Keeps the existing function signature used by the website.
create or replace function public.finish_attempt(p_attempt uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_status text;
  v_total integer;
  v_correct integer;
begin
  select status, question_count
    into v_status, v_total
  from public.attempts
  where id = p_attempt and user_id = v_user
  for update;

  if v_status is null then raise exception 'Попытка не найдена'; end if;
  if v_status = 'finished' then
    -- Return existing saved values instead of failing when the client retries finish.
    return (select jsonb_build_object('attempt_id', id, 'question_count', question_count,
      'correct_count', correct_count, 'percent', percent)
      from public.attempts where id = p_attempt and user_id = v_user);
  end if;

  select count(*) filter (where aa.chosen_option_id = qa.correct_option_id)::integer
    into v_correct
  from public.attempt_answers aa
  left join public.question_answers qa on qa.question_id = aa.question_id
  where aa.attempt_id = p_attempt and aa.chosen_option_id is not null;

  update public.attempts
  set status = 'finished', finished_at = now(), correct_count = coalesce(v_correct, 0),
      duration_seconds = extract(epoch from now() - created_at)::integer
  where id = p_attempt and user_id = v_user;

  return (select jsonb_build_object('attempt_id', id, 'question_count', question_count,
      'correct_count', correct_count, 'percent', percent)
    from public.attempts where id = p_attempt and user_id = v_user);
end;
$$;

revoke all on function public.finish_attempt(uuid) from public, anon;
grant execute on function public.finish_attempt(uuid) to authenticated;

-- Repair scores of already-finished attempts as well, so the homepage can show correct historical totals.
update public.attempts a
set correct_count = coalesce((
  select count(*)::integer
  from public.attempt_answers aa
  join public.question_answers qa on qa.question_id = aa.question_id
  where aa.attempt_id = a.id
    and aa.chosen_option_id = qa.correct_option_id
), 0)
where a.status = 'finished';
