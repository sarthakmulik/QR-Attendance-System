-- =========================================================================
-- PROJECTOR DISPLAY (Smart Classroom) — missing database objects
-- Run this once in the Supabase SQL editor, AFTER schema_security_repair.sql.
--
-- The frontend references two objects that were never added to the repo
-- schema (they broke useClasses and the /display/:classId/:token page):
--   1) public.classes.display_token  (src/hooks/queries.ts, src/pages/admin/Departments.tsx)
--   2) public.get_projector_session  (src/pages/public/ProjectorDisplay.tsx)
--
-- SECURITY NOTE: the projector page is an intentionally public route. The
-- display_token is a capability URL secret: anyone holding the full URL can
-- watch the live QR for that classroom. This is by design (projectors are
-- not logged in), and attendance itself remains protected server-side by
-- mark_attendance (login + enrollment + rotating token + geofence).
-- =========================================================================

-- 1) Per-class display token
ALTER TABLE public.classes ADD COLUMN IF NOT EXISTS display_token TEXT;

-- Normalize the column to TEXT. An earlier attempt may have created
-- display_token as uuid; the IF NOT EXISTS above would then be a no-op and
-- every statement below would fail with a type mismatch.
ALTER TABLE public.classes
    ALTER COLUMN display_token DROP DEFAULT;

ALTER TABLE public.classes
    ALTER COLUMN display_token TYPE TEXT
    USING display_token::text;

UPDATE public.classes
SET display_token = encode(gen_random_bytes(16), 'hex')
WHERE display_token IS NULL;

ALTER TABLE public.classes
    ALTER COLUMN display_token SET DEFAULT encode(gen_random_bytes(16), 'hex');

-- 2) Public RPC used by ProjectorDisplay.tsx
--    Returns the current active session for a class when the display token
--    matches. Returns {success:true, session:null} when idle (no session).
--
-- The live DB already contains an older overload of this function with a
-- uuid token parameter (same out-of-repo change that created display_token
-- as uuid). Two overloads make PostgREST unable to resolve the RPC call
-- (ERROR PGRST203), so drop EVERY existing overload first, then create
-- exactly one with a TEXT token.
DO $$
DECLARE v_sig TEXT;
BEGIN
    FOR v_sig IN
        SELECT p.oid::regprocedure::text
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'get_projector_session'
    LOOP
        EXECUTE format('DROP FUNCTION %s', v_sig);
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.get_projector_session(
    p_class_id UUID,
    p_display_token TEXT
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_token TEXT;
    v_session RECORD;
BEGIN
    IF p_class_id IS NULL OR p_display_token IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'Invalid URL parameters.');
    END IF;

    SELECT display_token INTO v_token FROM public.classes WHERE id = p_class_id;

    IF v_token IS NULL OR v_token <> p_display_token THEN
        RETURN json_build_object('success', false, 'message', 'Invalid or unknown projector link. Ask the Class Teacher to re-copy it.');
    END IF;

    -- Lazily close any expired session first. Best-effort: expiry is also
    -- enforced by the WHERE clause below, so a missing or broken cleanup
    -- function must never break the projector display.
    BEGIN
        PERFORM public.cleanup_expired_sessions();
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'cleanup_expired_sessions skipped: %', SQLERRM;
    END;

    SELECT
        s.id,
        s.expires_at,
        s.session_secret,
        COALESCE(sub.name, 'Ad-Hoc Session') AS subject_name,
        (f.first_name || ' ' || f.last_name) AS faculty_name
    INTO v_session
    FROM public.attendance_sessions s
    LEFT JOIN public.timetable t ON s.timetable_id = t.id
    LEFT JOIN public.subjects sub ON COALESCE(t.subject_id, s.subject_id) = sub.id
    LEFT JOIN public.users f ON s.faculty_id = f.id
    WHERE s.class_id = p_class_id
      AND s.is_active = true
      AND (s.expires_at IS NULL OR s.expires_at > NOW())
    ORDER BY s.created_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
        -- Not an error: the projector idles between lectures.
        RETURN json_build_object('success', true, 'session', NULL);
    END IF;

    RETURN json_build_object(
        'success', true,
        'session', json_build_object(
            'id', v_session.id,
            'subject_name', v_session.subject_name,
            'faculty_name', v_session.faculty_name,
            'session_secret', v_session.session_secret,
            'expires_at', v_session.expires_at
        )
    );
END;
$$;

-- The projector page is public (no login): the display_token is the only gate.
GRANT EXECUTE ON FUNCTION public.get_projector_session(UUID, TEXT) TO anon;
GRANT EXECUTE ON FUNCTION public.get_projector_session(UUID, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
