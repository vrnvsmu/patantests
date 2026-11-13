-- 0018_exam_additional_turntables.sql
-- Добавляет два дополнительных экзаменационных задания.
-- Тексты и варианты ответа после создания редактируются в админке.
begin;

do $$
declare
  v_topic_id bigint;
  v_question_id uuid;
  v_correct_id uuid;
  v_path text;
  v_prompt text;
  v_block text;
  v_label text;
  item record;
begin
  select id, block into v_topic_id, v_block
  from public.topics
  order by case when block = 'specific' then 0 else 1 end, sort_order, id
  limit 1;

  for item in select * from (values
    ('360:/assets/exam/bullez-emphysema', 'Определите патологический процесс по макропрепарату (эмфизема).'),
    ('360:/assets/exam/spleen-amyloidosis', 'Определите патологический процесс по макропрепарату (селезёнка).')
  ) as x(path, prompt)
  loop
    select id into v_question_id from public.questions where image_path=item.path limit 1;
    if v_question_id is null then
      insert into public.questions(section, block, topic_id, prompt, image_path, is_exam, is_published)
      values ('macro', coalesce(v_block,'general'), v_topic_id, item.prompt, item.path, true, false)
      returning id into v_question_id;

      insert into public.question_options(question_id, option_text, sort_order)
      values (v_question_id,'Вариант ответа 1',0),(v_question_id,'Вариант ответа 2',1),
             (v_question_id,'Вариант ответа 3',2),(v_question_id,'Вариант ответа 4',3);
      select id into v_correct_id from public.question_options where question_id=v_question_id and sort_order=0;
      insert into public.question_answers(question_id, correct_option_id) values(v_question_id,v_correct_id);
    end if;
  end loop;
end $$;
commit;
