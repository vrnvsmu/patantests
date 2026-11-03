-- 0008_admin_fixes.sql
-- Разрешает администратору загружать картинки главной страницы (папка site-content)
-- в хранилище testpatan-media. Безопасно запускать повторно.
begin;
drop policy if exists "admin upload site content" on storage.objects;
create policy "admin upload site content" on storage.objects for insert to authenticated
  with check (bucket_id = 'testpatan-media' and (storage.foldername(name))[1] = 'site-content' and public.is_admin());
drop policy if exists "admin update site content" on storage.objects;
create policy "admin update site content" on storage.objects for update to authenticated
  using (bucket_id = 'testpatan-media' and (storage.foldername(name))[1] = 'site-content' and public.is_admin())
  with check (bucket_id = 'testpatan-media' and (storage.foldername(name))[1] = 'site-content' and public.is_admin());
drop policy if exists "admin delete site content" on storage.objects;
create policy "admin delete site content" on storage.objects for delete to authenticated
  using (bucket_id = 'testpatan-media' and (storage.foldername(name))[1] = 'site-content' and public.is_admin());
commit;

-- ===== Статистика ответов: учитываем только ПЕРВУЮ попытку каждого пользователя =====
-- Для каждой пары (пользователь, вопрос, режим) берётся самый ранний завершённый ответ.
-- Гостевые попытки (user_id is null) отдельных пользователей не образуют и считаются как есть.
-- Тест «Избранное» в статистику не входит.
begin;
drop function if exists public.admin_question_statistics();
create function public.admin_question_statistics()
returns table(mode text, topic_id bigint, topic_title text, question_id uuid, prompt text, image_path text,
              total_answers bigint, correct_count bigint, correct_rate numeric,
              option_id uuid, option_text text, is_correct boolean, selected_count bigint)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Только для администратора'; end if;
  return query
  with first_ans as (
    select distinct on (coalesce(a.user_id::text, a.id::text), aa.question_id, a.mode)
           a.mode as f_mode, aa.question_id as f_q, aa.chosen_option_id as f_opt, coalesce(aa.is_correct,false) as f_ok
    from public.attempt_answers aa
    join public.attempts a on a.id = aa.attempt_id
    where a.status = 'finished' and a.mode <> 'favorites' and aa.chosen_option_id is not null
    order by coalesce(a.user_id::text, a.id::text), aa.question_id, a.mode, a.finished_at, aa.answered_at
  ), agg as (
    select f_mode, f_q, count(*)::bigint as tot, count(*) filter (where f_ok)::bigint as cor from first_ans group by f_mode, f_q
  ), sel as (
    select f_mode, f_q, f_opt, count(*)::bigint as n from first_ans group by f_mode, f_q, f_opt
  )
  select g.f_mode, q.topic_id, coalesce(t.title, 'Без темы'), q.id, q.prompt, q.image_path,
         g.tot, g.cor, round(g.cor * 100.0 / nullif(g.tot, 0), 1),
         o.id, o.option_text, (o.id = k.correct_option_id), coalesce(s.n, 0)
  from agg g
  join public.questions q on q.id = g.f_q
  left join public.topics t on t.id = q.topic_id
  left join public.question_answers k on k.question_id = q.id
  join public.question_options o on o.question_id = q.id
  left join sel s on s.f_mode = g.f_mode and s.f_q = g.f_q and s.f_opt = o.id
  order by g.f_mode, q.topic_id, q.id, o.sort_order;
end $$;
revoke all on function public.admin_question_statistics() from public, anon;
grant execute on function public.admin_question_statistics() to authenticated;
commit;
