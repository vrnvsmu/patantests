-- Раздельная блокировка каждой темы для режимов Макро, Микро и Теория.
-- Текущий is_locked переносится в каждый новый флаг, чтобы сохранить существующие настройки.
alter table public.topics
  add column if not exists is_locked_macro boolean,
  add column if not exists is_locked_micro boolean,
  add column if not exists is_locked_theory boolean;

update public.topics
set is_locked_macro = coalesce(is_locked_macro, is_locked, false),
    is_locked_micro = coalesce(is_locked_micro, is_locked, false),
    is_locked_theory = coalesce(is_locked_theory, is_locked, false);

alter table public.topics
  alter column is_locked_macro set default false,
  alter column is_locked_macro set not null,
  alter column is_locked_micro set default false,
  alter column is_locked_micro set not null,
  alter column is_locked_theory set default false,
  alter column is_locked_theory set not null;
