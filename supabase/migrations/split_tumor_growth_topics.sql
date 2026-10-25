-- Разделение темы «Опухолевый рост» на две темы.
-- Выполнить один раз в Supabase → SQL Editor.
-- Существующие вопросы останутся привязаны к первой теме; новые можно добавлять в обе.

begin;

-- Переименовываем существующую тему, чтобы сохранить её ID и связи с вопросами.
update public.topics
set title = 'Общее об опухолях. Эпителиальные опухоли',
    sort_order = 10
where block = 'general'
  and title = 'Опухолевый рост';

-- Добавляем вторую тему. Повторный запуск не создаст дубликат.
insert into public.topics (block, title, sort_order)
values ('general', 'Опухоли мезенхимальные, меланинобразующей и нервной тканей', 11)
on conflict (block, title) do update
set sort_order = excluded.sort_order;

commit;
