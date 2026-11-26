-- Apply AFTER 0009_guest_api.sql, on Neon branch test.
-- The guest runtime only needs EXECUTE on SECURITY DEFINER functions.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM testpatan_guest_api;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM testpatan_guest_api;
-- Avoid exposing unpublished 360 sets by UUID.
CREATE OR REPLACE FUNCTION public.guest_turntable(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $$
 SELECT coalesce((SELECT jsonb_build_object('id',s.id,'title',s.title,'frame_paths',s.frame_paths)
 FROM public.turntable_sets s WHERE s.id=p_id AND EXISTS(SELECT 1 FROM public.questions q WHERE q.is_published AND q.image_path='360:storage:'||s.id::text)),'null'::jsonb)
$$;
REVOKE ALL ON FUNCTION public.guest_turntable(uuid) FROM PUBLIC,anonymous,authenticated;
GRANT EXECUTE ON FUNCTION public.guest_turntable(uuid) TO testpatan_guest_api;
