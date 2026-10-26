-- Сохранение состояния незавершённой попытки для продолжения на другом устройстве.
-- Выполнить один раз в Supabase SQL Editor.

create table if not exists public.attempt_states (
  attempt_id uuid primary key references public.attempts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  state jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.attempt_states enable row level security;
revoke all on public.attempt_states from anon, authenticated, public;

create or replace function public.save_my_attempt_state(p_attempt_id uuid, p_state jsonb)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'Authentication required';
  end if;
  if p_state is null or jsonb_typeof(p_state) <> 'object' then
    raise exception 'Invalid attempt state';
  end if;
  if not exists (
    select 1 from public.attempts a
    where a.id = p_attempt_id and a.user_id = v_user
  ) then
    raise exception 'Attempt not found or access denied';
  end if;

  insert into public.attempt_states(attempt_id, user_id, state, updated_at)
  values (p_attempt_id, v_user, p_state, now())
  on conflict (attempt_id) do update
    set state = public.attempt_states.state || excluded.state, updated_at = now()
    where public.attempt_states.user_id = v_user;

  return true;
end;
$$;

create or replace function public.get_my_attempt_state(p_attempt_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_state jsonb;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select s.state into v_state
  from public.attempt_states s
  join public.attempts a on a.id = s.attempt_id
  where s.attempt_id = p_attempt_id
    and s.user_id = auth.uid()
    and a.user_id = auth.uid();

  return v_state;
end;
$$;

revoke all on function public.save_my_attempt_state(uuid, jsonb) from public, anon;
revoke all on function public.get_my_attempt_state(uuid) from public, anon;
grant execute on function public.save_my_attempt_state(uuid, jsonb) to authenticated;
grant execute on function public.get_my_attempt_state(uuid) to authenticated;
