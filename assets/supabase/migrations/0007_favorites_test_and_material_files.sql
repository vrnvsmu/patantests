-- 0007_favorites_test_and_material_files.sql
-- 1) Тест из избранных вопросов; 2) загрузка файлов в «Учебные материалы».
-- Применить в Supabase: SQL Editor -> вставить файл целиком -> Run.
begin;

-- ===== 1. Тест по избранному =====
alter table public.attempts drop constraint if exists attempts_mode_check;
alter table public.attempts add constraint attempts_mode_check
  check (mode in ('macro','micro','theory','exam','favorites'));

create or replace function public.start_favorites_attempt(p_count integer default 20)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_ids uuid[]; v_attempt uuid;
begin
  if v_user is null then raise exception 'Войдите, чтобы решать избранные вопросы'; end if;
  p_count := least(greatest(coalesce(p_count, 20), 1), 50);

  if (select count(*) from public.attempts where user_id = v_user and created_at > now() - interval '1 hour') >= 30 then
    raise exception 'Слишком много попыток за час, попробуйте позже';
  end if;
  delete from public.attempts where user_id = v_user and status = 'in_progress' and created_at < now() - interval '1 day';

  select array_agg(id) into v_ids from (
    select q.id from public.question_favorites f
    join public.questions q on q.id = f.question_id
    where f.user_id = v_user and q.is_published
      and exists (select 1 from public.question_answers a where a.question_id = q.id)
    order by random() limit p_count
  ) s;
  if v_ids is null then raise exception 'В избранном нет доступных вопросов'; end if;

  insert into public.attempts(user_id, mode, topic_id, question_count)
  values (v_user, 'favorites', null, array_length(v_ids, 1)) returning id into v_attempt;
  insert into public.attempt_answers(attempt_id, question_id) select v_attempt, unnest(v_ids);

  return jsonb_build_object('attempt_id', v_attempt, 'questions', (
    select jsonb_agg(jsonb_build_object('id', q.id, 'prompt', q.prompt, 'image_path', q.image_path,
      'options', (select jsonb_agg(jsonb_build_object('id', o.id, 'text', o.option_text) order by o.sort_order)
                  from public.question_options o where o.question_id = q.id)))
    from public.questions q where q.id = any(v_ids)));
end $$;

revoke all on function public.start_favorites_attempt(integer) from public, anon;
grant execute on function public.start_favorites_attempt(integer) to authenticated;

-- ===== 2. Файлы материалов =====
alter table public.learning_materials add column if not exists file_path text;
alter table public.learning_materials add column if not exists file_name text;
alter table public.learning_materials add column if not exists file_size bigint;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('testpatan-materials', 'testpatan-materials', true, 26214400, array[
  'application/pdf','application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-powerpoint',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.oasis.opendocument.text','application/vnd.oasis.opendocument.presentation',
  'application/vnd.oasis.opendocument.spreadsheet',
  'text/plain','application/rtf','text/rtf','application/octet-stream'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "public read testpatan materials" on storage.objects;
create policy "public read testpatan materials" on storage.objects for select
  using (bucket_id = 'testpatan-materials');
drop policy if exists "admin upload materials" on storage.objects;
create policy "admin upload materials" on storage.objects for insert to authenticated
  with check (bucket_id = 'testpatan-materials' and public.is_admin());
drop policy if exists "admin update materials" on storage.objects;
create policy "admin update materials" on storage.objects for update to authenticated
  using (bucket_id = 'testpatan-materials' and public.is_admin())
  with check (bucket_id = 'testpatan-materials' and public.is_admin());
drop policy if exists "admin delete materials" on storage.objects;
create policy "admin delete materials" on storage.objects for delete to authenticated
  using (bucket_id = 'testpatan-materials' and public.is_admin());

commit;
