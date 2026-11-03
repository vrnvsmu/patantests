-- Добавляет признак временной блокировки темы
alter table public.topics
  add column if not exists is_locked boolean not null default false;
