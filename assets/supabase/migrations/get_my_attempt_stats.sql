-- Безопасная статистика ответов пользователя без прямого доступа к attempt_answers.
-- Выполнить один раз в Supabase SQL Editor.
create or replace function public.get_my_attempt_stats(p_attempt_ids uuid[])
returns table (
  attempt_id uuid,
  answered_count bigint,
  correct_count bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select aa.attempt_id,
         count(*) filter (where aa.chosen_option_id is not null) as answered_count,
         count(*) filter (where aa.chosen_option_id is not null and aa.is_correct is true) as correct_count
  from public.attempt_answers aa
  join public.attempts a on a.id = aa.attempt_id
  where a.user_id = auth.uid()
    and aa.attempt_id = any(coalesce(p_attempt_ids, '{}'::uuid[]))
  group by aa.attempt_id;
$$;

revoke all on function public.get_my_attempt_stats(uuid[]) from public, anon;
grant execute on function public.get_my_attempt_stats(uuid[]) to authenticated;
