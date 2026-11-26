-- Run after a successful import in the Neon TEST branch.
SELECT 'admins' AS table_name, count(*) AS rows FROM public.admins
UNION ALL SELECT 'attempt_answers', count(*) FROM public.attempt_answers
UNION ALL SELECT 'attempt_states', count(*) FROM public.attempt_states
UNION ALL SELECT 'attempts', count(*) FROM public.attempts
UNION ALL SELECT 'profiles', count(*) FROM public.profiles
UNION ALL SELECT 'learning_materials', count(*) FROM public.learning_materials
UNION ALL SELECT 'notifications', count(*) FROM public.notifications
UNION ALL SELECT 'question_answers', count(*) FROM public.question_answers
UNION ALL SELECT 'question_comments', count(*) FROM public.question_comments
UNION ALL SELECT 'question_favorites', count(*) FROM public.question_favorites
UNION ALL SELECT 'question_options', count(*) FROM public.question_options
UNION ALL SELECT 'question_trash', count(*) FROM public.question_trash
UNION ALL SELECT 'questions', count(*) FROM public.questions
UNION ALL SELECT 'site_content', count(*) FROM public.site_content
UNION ALL SELECT 'topics', count(*) FROM public.topics
UNION ALL SELECT 'turntable_sets', count(*) FROM public.turntable_sets
ORDER BY table_name;

SELECT count(*) AS public_functions
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public';

SELECT count(*) AS rls_enabled_tables
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' AND c.relkind='r' AND c.relrowsecurity;

SELECT count(*) AS rls_policies
FROM pg_policies WHERE schemaname='public';

SELECT to_regclass('public.leaderboard') AS leaderboard_view,
       to_regclass('public.legacy_user_map') AS legacy_user_map,
       to_regprocedure('public.claim_legacy_account()') AS claim_rpc;
