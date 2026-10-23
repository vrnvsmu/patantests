-- Рейтинг по трём разделам: macro (макро + экзамен), micro, theory.
-- Выполнять после 0002. В рейтинг идут завершённые тесты из 5+ вопросов; нужно минимум 3 таких теста в разделе.
drop view if exists public.leaderboard;
create view public.leaderboard as
select row_number() over (partition by category order by average_percent desc, correct_answers desc, attempts desc) as place, t.*
from (
  select case when a.mode in ('macro','exam') then 'macro' else a.mode end as category,
         p.id as user_id, p.nickname, p.avatar_url,
         count(a.id)::integer as attempts,
         round(avg(a.percent), 2) as average_percent,
         sum(a.correct_count)::bigint as correct_answers
  from public.profiles p join public.attempts a on a.user_id = p.id
  where a.status = 'finished' and a.question_count >= 5
  group by 1, p.id, p.nickname, p.avatar_url
  having count(a.id) >= 3) t;
grant select on public.leaderboard to anon, authenticated;
