-- Безопасное удаление собственных попыток из раздела «Статистика».
-- Запустить один раз в Supabase → SQL Editor.
-- Связанные строки attempt_answers удаляются каскадно по FK attempt_id.

create or replace function public.delete_my_attempts(p_attempt_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deleted integer := 0;
begin
  if auth.uid() is null then
    raise exception 'Требуется вход';
  end if;

  if p_attempt_ids is null or cardinality(p_attempt_ids) = 0 then
    return 0;
  end if;

  delete from public.attempts
   where user_id = auth.uid()
     and id = any(p_attempt_ids);

  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke all on function public.delete_my_attempts(uuid[]) from public, anon;
grant execute on function public.delete_my_attempts(uuid[]) to authenticated;
