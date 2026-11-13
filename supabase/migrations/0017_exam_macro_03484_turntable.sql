-- 0017_exam_macro_03484_turntable.sql
-- Первое экзаменационное задание: макропрепарат 03484 с 360° просмотром.
-- Кадры лежат в public/assets/exam/macro-03484/ и подключаются через специальный image_path.
-- Текст задания и варианты ответа можно изменить в админке после применения миграции.
begin;

do $$
declare
  v_topic_id bigint;
  v_question_id uuid;
  v_correct_id uuid;
begin
  select id into v_topic_id
  from public.topics
  order by case when block = 'specific' then 0 else 1 end, sort_order, id
  limit 1;

  select id into v_question_id
  from public.questions
  where image_path = '360:/assets/exam/macro-03484'
    and is_exam = true
  limit 1;

  if v_question_id is null then
    insert into public.questions
      (section, block, topic_id, prompt, image_path, is_exam, is_published)
    values
      (
        'macro',
        coalesce((select block from public.topics where id = v_topic_id), 'general'),
        v_topic_id,
        'Определите патологический процесс по макропрепарату.',
        '360:/assets/exam/macro-03484',
        true,
        true
      )
    returning id into v_question_id;

    insert into public.question_options (question_id, option_text, sort_order)
    values
      (v_question_id, 'Вариант ответа 1', 0),
      (v_question_id, 'Вариант ответа 2', 1),
      (v_question_id, 'Вариант ответа 3', 2),
      (v_question_id, 'Вариант ответа 4', 3);

    select id into v_correct_id
    from public.question_options
    where question_id = v_question_id and sort_order = 0;

    insert into public.question_answers (question_id, correct_option_id)
    values (v_question_id, v_correct_id);
  end if;
end $$;

commit;
