-- =========================================================================
-- SCHEMA FLOW FIXES (live-DB patch, fully re-runnable)
-- File: supabase/schema_flow_fixes.sql
--
-- Run in the Supabase SQL editor AFTER schema_bugfix_pass.sql. Re-runnable —
-- drop-first loops + guarded DDL everywhere. Companion to docs/DESIGN_NEXT_PHASE.md.
--
-- Contents:
--   A) Enrollments: MOVE-WITH-HISTORY
--      - active flag + ended_at; trigger enforces "one active enrollment per
--        student" and reactivates returning enrollments, regardless of which
--        RPC/table path inserts (invite, signup auto-enroll, enroll_student).
--   B) One-active-session-per-slot (timetable_id, date) — duplicate active
--      sessions auto-closed (newest kept), then a unique partial index.
--   C) webhook_events (ERP outbox for §5.4 of the design doc) + private
--      helpers _absentify_session / _append_session_closed_event.
--   D) cleanup_expired_sessions now also writes the ABSENCE ledger + webhook.
--   E) close_session(session_id): idempotent close + absence ledger + event.
--   F) mark_attendance: 6-arg canonical (adds p_gps_accuracy), 50 m geofence
--      with accuracy compensation (credit capped at 25 m), enrollment+is_active
--      checks folded INTO the insert (kills the TOCTOU windows), division gate
--      uses active enrollments. 5-arg overload kept as a thin bridge so a
--      not-yet-updated frontend can keep calling the old signature.
--   G) is_student_in_scope: active enrollments only.
--   H) Stats RPCs + defaulters + dashboard + 3 summaries + user hierarchy:
--      enrollment windows (sessions count only while actually enrolled) and
--      absent rows excluded from "attended", absent excluded from recent scans.
--   I) Grants + PostgREST reload.
-- =========================================================================


-- =========================================================================
-- A) ENROLLMENTS: MOVE WITH HISTORY
-- =========================================================================
ALTER TABLE public.enrollments
    ADD COLUMN IF NOT EXISTS active BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE public.enrollments
    ADD COLUMN IF NOT EXISTS ended_at TIMESTAMPTZ;
ALTER TABLE public.enrollments
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

CREATE INDEX IF NOT EXISTS idx_enrollments_student_active
    ON public.enrollments (student_id) WHERE active IS TRUE;

-- MOVE logic lives in ONE trigger so every write path benefits:
--   * INSERT into a NEW class      -> closes that student's other active rows
--   * INSERT onto an OLD (closed) row of the same student+class -> reactivates
--     it (roll on conflict taken only if provided) and closes others
--   * explicit UPDATE SET active=true -> same close-others behaviour
-- (ON CONFLICT DO UPDATE on a closed row would otherwise leave it inactive —
--  handled here by reacting at the BEFORE INSERT level and cancelling the
--  insert, so we own reactivation fully.)
CREATE OR REPLACE FUNCTION public.enforce_single_active_enrollment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_existing public.enrollments;
BEGIN
    IF NEW.active IS NOT TRUE THEN
        -- Closing/keeping closed: ensure a close time exists
        IF NEW.ended_at IS NULL AND NEW.active IS NOT TRUE THEN
            NEW.ended_at := NOW();
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP = 'INSERT' THEN
        SELECT * INTO v_existing
        FROM public.enrollments
        WHERE student_id = NEW.student_id AND class_id = NEW.class_id;

        IF FOUND THEN
            -- Reactivation of a historical row: cancel this insert, update the
            -- original instead. The UPDATE below re-fires this trigger
            -- (UPDATE OF active), which closes the student's other active rows.
            UPDATE public.enrollments
               SET active = TRUE,
                   ended_at = NULL,
                   roll_number = COALESCE(NEW.roll_number, v_existing.roll_number),
                   updated_at = NOW()
             WHERE id = v_existing.id;
            RETURN NULL;
        END IF;
    END IF;

    -- Close every other active enrollment of this student (MOVE semantics)
    UPDATE public.enrollments
       SET active = FALSE,
           ended_at = COALESCE(ended_at, NOW())
     WHERE student_id = NEW.student_id
       AND id <> NEW.id
       AND active IS TRUE;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_move_with_history ON public.enrollments;
CREATE TRIGGER trg_move_with_history
    BEFORE INSERT OR UPDATE OF active ON public.enrollments
    FOR EACH ROW EXECUTE FUNCTION public.enforce_single_active_enrollment();

-- One-time visibility: students currently enrolled in more than one class.
DO $$
DECLARE
    v_duals BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_duals
    FROM (
        SELECT student_id
        FROM public.enrollments
        WHERE active IS TRUE
        GROUP BY student_id
        HAVING COUNT(*) > 1
    ) x;
    IF v_duals > 0 THEN
        RAISE NOTICE 'Legacy data: % student(s) still hold multiple ACTIVE enrollments. They keep working until their next assignment, which will automatically move them (history preserved).', v_duals;
    END IF;
END $$;


-- =========================================================================
-- B) ONE ACTIVE SESSION PER TIMETABLE SLOT
-- =========================================================================
-- Auto-close duplicate active sessions for the same (timetable, date),
-- keeping the newest. Safe: cleanup_expired_sessions() already treats
-- stale-active sessions as garbage; this only collapses exact duplicates.
DO $$
DECLARE
    v_dupes BIGINT;
BEGIN
    WITH ranked AS (
        SELECT id,
               ROW_NUMBER() OVER (
                   PARTITION BY timetable_id, date
                   ORDER BY created_at DESC, id
               ) AS rn
        FROM public.attendance_sessions
        WHERE is_active = true AND timetable_id IS NOT NULL
    )
    UPDATE public.attendance_sessions s
       SET is_active = false
      FROM ranked r
     WHERE s.id = r.id AND r.rn > 1;
    GET DIAGNOSTICS v_dupes = ROW_COUNT;
    IF v_dupes > 0 THEN
        RAISE NOTICE 'Closed % duplicate active session(s) (same timetable slot, same day); newest kept.', v_dupes;
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_one_active_session_per_slot
    ON public.attendance_sessions (timetable_id, date)
    WHERE is_active = true AND timetable_id IS NOT NULL;


-- =========================================================================
-- C) ERP OUTBOX + PRIVATE HELPERS
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.webhook_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    college_id UUID REFERENCES public.colleges(id) ON DELETE CASCADE,
    session_id UUID REFERENCES public.attendance_sessions(id) ON DELETE SET NULL,
    event_type TEXT NOT NULL,
    payload JSONB NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',          -- pending|delivered|failed|dead
    attempts INTEGER NOT NULL DEFAULT 0,
    next_retry_at TIMESTAMPTZ,
    last_status_code INTEGER,
    last_error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    delivered_at TIMESTAMPTZ
);

ALTER TABLE public.webhook_events ENABLE ROW LEVEL SECURITY;
-- No policies on purpose: locked down. SECURITY DEFINER functions (table
-- owner, postgres) can still write. The future Edge-Function dispatcher uses
-- the service role, which bypasses RLS.
REVOKE ALL ON public.webhook_events FROM anon, authenticated;

CREATE INDEX IF NOT EXISTS idx_webhook_events_dispatch
    ON public.webhook_events (status, next_retry_at NULLS FIRST)
    WHERE status = 'pending';

-- Private helper: create ABSENT ledger rows for a closed session.
-- Idempotent; returns the number of rows inserted (0 safe to re-run).
CREATE OR REPLACE FUNCTION public._absentify_session(p_session_id UUID, p_class_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_inserted BIGINT := 0;
BEGIN
    IF p_session_id IS NULL OR p_class_id IS NULL THEN
        RETURN 0;
    END IF;

    INSERT INTO public.attendance_records (session_id, student_id, status)
    SELECT p_session_id, e.student_id, 'absent'::public.attendance_status
    FROM public.enrollments e
    WHERE e.class_id = p_class_id
      AND e.active IS TRUE
      AND NOT EXISTS (
            SELECT 1 FROM public.attendance_records r
            WHERE r.session_id = p_session_id AND r.student_id = e.student_id
          )
    ON CONFLICT (session_id, student_id) DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    RETURN v_inserted::int;
END;
$$;
REVOKE ALL ON FUNCTION public._absentify_session(UUID, UUID) FROM PUBLIC, anon, authenticated;

-- Private helper: append the session.closed outbox event (once per session).
CREATE OR REPLACE FUNCTION public._append_session_closed_event(
    p_session_id UUID,
    p_class_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_session RECORD;
    v_subject TEXT;
    v_faculty TEXT;
    v_manifest JSON;
    v_college UUID;
BEGIN
    IF p_session_id IS NULL OR p_class_id IS NULL THEN
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.webhook_events
        WHERE session_id = p_session_id AND event_type = 'session.closed'
    ) THEN
        RETURN;  -- idempotent: one event per session, ever
    END IF;

    SELECT * INTO v_session FROM public.attendance_sessions WHERE id = p_session_id;
    IF NOT FOUND THEN RETURN; END IF;

    SELECT sub.name INTO v_subject
    FROM public.subjects sub
    WHERE sub.id = COALESCE(v_session.subject_id, (
            SELECT t.subject_id FROM public.timetable t WHERE t.id = v_session.timetable_id));

    SELECT u.first_name || ' ' || u.last_name INTO v_faculty
    FROM public.users u WHERE u.id = v_session.faculty_id;

    SELECT col.id INTO v_college
    FROM public.classes c2
    JOIN public.departments d2 ON d2.id = c2.department_id
    JOIN public.colleges col ON col.id = d2.college_id
    WHERE c2.id = p_class_id;

    SELECT json_build_object(
        'session_id', v_session.id,
        'class_id', p_class_id,
        'date', v_session.date,
        'subject_name', COALESCE(v_subject, 'Ad-Hoc Session'),
        'faculty_name', v_faculty,
        'attendance', (
            SELECT json_agg(json_build_object('student_id', r.student_id, 'status', r.status))
            FROM public.attendance_records r
            WHERE r.session_id = p_session_id
        )
    ) INTO v_manifest;

    INSERT INTO public.webhook_events (college_id, session_id, event_type, payload)
    VALUES (v_college, p_session_id, 'session.closed', v_manifest);
END;
$$;
REVOKE ALL ON FUNCTION public._append_session_closed_event(UUID, UUID) FROM PUBLIC, anon, authenticated;


-- =========================================================================
-- D) CLEANUP: now also writes the absence ledger + outbox events
-- =========================================================================
CREATE OR REPLACE FUNCTION public.cleanup_expired_sessions()
RETURNS void AS $$
DECLARE
    v_row RECORD;
    v_absents INTEGER;
BEGIN
    FOR v_row IN
        WITH closed AS (
            UPDATE public.attendance_sessions
               SET is_active = false
             WHERE is_active = true
               AND expires_at IS NOT NULL
               AND expires_at <= NOW()
            RETURNING id, class_id, timetable_id
        )
        SELECT closed.id AS session_id,
               COALESCE(closed.class_id, t.class_id) AS class_id
        FROM closed
        LEFT JOIN public.timetable t ON t.id = closed.timetable_id
    LOOP
        v_absents := public._absentify_session(v_row.session_id, v_row.class_id);
        PERFORM public._append_session_closed_event(v_row.session_id, v_row.class_id);
        IF v_absents > 0 THEN
            RAISE NOTICE 'Session % auto-expired: % absence row(s) recorded.', v_row.session_id, v_absents;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- =========================================================================
-- E) close_session: explicit close used by the End Lecture button and
--    available to oversight roles. Idempotent.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.close_session(p_session_id UUID)
RETURNS json AS $$
DECLARE
    v_user UUID := auth.uid();
    v_role public.user_role;
    v_dept UUID;
    v_college UUID;
    v_session RECORD;
    v_authorized BOOLEAN := false;
    v_just_closed BOOLEAN := false;
    v_absents INTEGER := 0;
BEGIN
    IF v_user IS NULL OR p_session_id IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'Unauthorized.');
    END IF;

    SELECT role, department_id, college_id INTO v_role, v_dept, v_college
    FROM public.users WHERE id = v_user;

    SELECT * INTO v_session FROM public.attendance_sessions WHERE id = p_session_id;
    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'message', 'Session not found.');
    END IF;

    -- Authorization: owning faculty, class teacher of the class, or oversight (super_admin/principal, hod within department)
    v_authorized :=
        (v_session.faculty_id = v_user)
        OR (v_role IN ('super_admin', 'principal'))
        OR (v_role = 'hod' AND EXISTS (
                SELECT 1 FROM public.classes c
                JOIN public.departments d ON d.id = c.department_id
                WHERE c.id = COALESCE(v_session.class_id, (
                        SELECT t.class_id FROM public.timetable t WHERE t.id = v_session.timetable_id))
                  AND d.id = v_dept))
        OR (v_role = 'class_teacher' AND EXISTS (
                SELECT 1 FROM public.classes c
                WHERE c.id = COALESCE(v_session.class_id, (
                        SELECT t.class_id FROM public.timetable t WHERE t.id = v_session.timetable_id))
                  AND c.class_teacher_id = v_user));

    IF NOT v_authorized THEN
        RETURN json_build_object('success', false, 'message', 'You are not allowed to end this session.');
    END IF;

    UPDATE public.attendance_sessions
       SET is_active = false
     WHERE id = p_session_id
       AND is_active = true;
    GET DIAGNOSTICS v_just_closed = ROW_COUNT > 0;

    -- Absence ledger is refreshed idempotently whether or not we just closed it
    v_absents := public._absentify_session(
        p_session_id,
        COALESCE(v_session.class_id, (
            SELECT t.class_id FROM public.timetable t WHERE t.id = v_session.timetable_id))
    );
    PERFORM public._append_session_closed_event(
        p_session_id,
        COALESCE(v_session.class_id, (
            SELECT t.class_id FROM public.timetable t WHERE t.id = v_session.timetable_id))
    );

    RETURN json_build_object(
        'success', true,
        'just_closed', v_just_closed,
        'absences_recorded', v_absents,
        'message', CASE WHEN v_just_closed
                        THEN 'Lecture ended. ' || v_absents || ' absence row(s) recorded.'
                        ELSE 'Session was already closed. Absence ledger refreshed.'
                   END
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions;

REVOKE ALL ON FUNCTION public.close_session(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.close_session(UUID) TO authenticated, service_role;


-- =========================================================================
-- F) MARK_ATTENDANCE — canonical 6-arg version + 5-arg bridge
-- =========================================================================
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS sig
        FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'public'
          AND p.proname = 'mark_attendance'
    LOOP
        EXECUTE format('DROP FUNCTION %s', r.sig);
    END LOOP;
    RAISE NOTICE 'mark_attendance overloads dropped for clean re-definition.';
END $$;

-- Canonical 6-arg version: adds p_gps_accuracy (scanner sends coords.accuracy).
-- Geofence is now SPEC-CORRECT: 50 m, compensated by GPS accuracy, credit
-- capped at 25 m so fake GPS with runaway accuracy still gets rejected:
--   effective_distance = max(0, distance - min(accuracy, 25))
--   reject when effective_distance > 50
-- Enrollment + session-active checks are folded INTO the INSERT itself
-- (single statement) — closes the division-gate/close-session TOCTOU windows.
CREATE OR REPLACE FUNCTION public.mark_attendance(
    p_session_id UUID,
    p_token VARCHAR,
    p_device_info TEXT DEFAULT NULL,
    p_lat FLOAT DEFAULT NULL,
    p_lng FLOAT DEFAULT NULL,
    p_gps_accuracy FLOAT DEFAULT NULL
)
RETURNS json AS $$
DECLARE
    v_session RECORD;
    v_student_id UUID;
    v_caller_role public.user_role;
    v_class_id UUID;
    v_class_lat FLOAT;
    v_class_lng FLOAT;
    v_distance FLOAT;
    v_credit FLOAT;
    v_window BIGINT;
    v_secret TEXT;
    v_token_ok BOOLEAN := false;
    v_inserted BIGINT := 0;
    v_device_id TEXT;
BEGIN
    v_student_id := auth.uid();
    IF v_student_id IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'Unauthorized. Please log in.');
    END IF;

    SELECT role INTO v_caller_role FROM public.users WHERE id = v_student_id;
    IF v_caller_role IS NULL OR v_caller_role NOT IN ('student', 'super_admin') THEN
        RETURN json_build_object('success', false, 'message', 'Only students can scan QR codes to mark attendance.');
    END IF;

    BEGIN
        PERFORM public.cleanup_expired_sessions();
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'cleanup_expired_sessions skipped: %', SQLERRM;
    END;

    SELECT * INTO v_session
    FROM public.attendance_sessions
    WHERE id = p_session_id;

    IF NOT FOUND OR NOT v_session.is_active THEN
        RETURN json_build_object('success', false, 'message', 'Session is not active or does not exist.');
    END IF;

    IF v_session.expires_at IS NOT NULL AND NOW() > v_session.expires_at THEN
        UPDATE public.attendance_sessions SET is_active = false WHERE id = p_session_id AND is_active = true;
        -- Expired while open: record the absence ledger + outbox event here too
        v_class_id := v_session.class_id;
        IF v_class_id IS NULL THEN
            SELECT t.class_id INTO v_class_id FROM public.timetable t WHERE t.id = v_session.timetable_id;
        END IF;
        PERFORM public._absentify_session(p_session_id, v_class_id);
        PERFORM public._append_session_closed_event(p_session_id, v_class_id);
        RETURN json_build_object('success', false, 'message', 'This lecture session has ended.');
    END IF;

    -- Rotating QR token (TOTP window +/- 1 == ~30s validity)
    v_window := floor(extract(epoch FROM now()) / 10);
    v_secret := v_session.session_secret::text;

    IF v_secret IS NOT NULL AND length(v_secret) > 0 THEN
        IF p_token = public.compute_session_token(v_secret, v_window)
           OR p_token = public.compute_session_token(v_secret, v_window - 1)
           OR p_token = public.compute_session_token(v_secret, v_window + 1) THEN
            v_token_ok := true;
        END IF;
    END IF;

    IF NOT v_token_ok AND v_session.current_token IS NOT NULL AND v_session.current_token = p_token THEN
        IF v_session.token_expires_at IS NULL OR NOW() <= v_session.token_expires_at THEN
            v_token_ok := true;
        END IF;
    END IF;

    IF NOT v_token_ok THEN
        RETURN json_build_object('success', false, 'message', 'Invalid or expired QR code.');
    END IF;

    -- Resolve the class for this session (ad-hoc uses class_id, scheduled uses timetable_id)
    v_class_id := v_session.class_id;
    IF v_class_id IS NULL AND v_session.timetable_id IS NOT NULL THEN
        SELECT class_id INTO v_class_id FROM public.timetable WHERE id = v_session.timetable_id;
    END IF;

    IF v_class_id IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'This session is not linked to a class. Attendance cannot be verified.');
    END IF;

    -- DEVICE ANTI-PROXY GATE: the same physical device may only mark ONE
    -- student per session (own earlier row handled by the ON CONFLICT reply).
    IF p_device_info IS NOT NULL AND length(trim(p_device_info)) > 0 THEN
        v_device_id := split_part(p_device_info, '|', 1);
        IF EXISTS (
            SELECT 1 FROM public.attendance_records r
            WHERE r.session_id = p_session_id
              AND r.device_info IS NOT NULL
              AND split_part(r.device_info, '|', 1) = v_device_id
              AND r.student_id <> v_student_id
        ) THEN
            RETURN json_build_object('success', false, 'message',
                'This device has already been used to mark attendance for another student in this session.');
        END IF;
    END IF;

    -- Geofence: 50 m with GPS-accuracy compensation (credit capped at 25 m).
    SELECT c.latitude, c.longitude INTO v_class_lat, v_class_lng
    FROM public.classes c
    WHERE c.id = v_class_id;

    IF v_class_lat IS NULL OR v_class_lng IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'Classroom location has not been set by the Class Teacher. Cannot verify attendance.');
    END IF;

    IF p_lat IS NULL OR p_lng IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'Your GPS location is required to mark attendance.');
    END IF;

    v_distance := public.haversine_distance(p_lat, p_lng, v_class_lat, v_class_lng);
    v_credit  := LEAST(COALESCE(p_gps_accuracy, 0.0), 25.0);

    IF (v_distance - v_credit) > 50.0 THEN
        RETURN json_build_object('success', false, 'message',
            'You are ' || round(v_distance::numeric, 1) || ' meters away. You must be within 50 meters of the classroom. If you are inside, step outdoors for a better GPS fix.');
    END IF;

    -- ATOMIC INSERT: session-active + active-enrollment are re-verified in the
    -- same statement that inserts, so an admin removing the enrollment (or a
    -- colleague closing the session) between the earlier checks and this insert
    -- can no longer let a stale scan through. ON CONFLICT DO NOTHING without a
    -- conflict target also falls back on the device-token partial index.
    INSERT INTO public.attendance_records (session_id, student_id, status, device_info)
    SELECT p_session_id, v_student_id, 'present', p_device_info
     WHERE EXISTS (
            SELECT 1 FROM public.attendance_sessions s
            WHERE s.id = p_session_id AND s.is_active = true)
       AND EXISTS (
            SELECT 1 FROM public.enrollments e
            WHERE e.student_id = v_student_id
              AND e.class_id = v_class_id
              AND e.active IS TRUE)
    ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    IF v_inserted = 0 THEN
        IF EXISTS (
            SELECT 1 FROM public.attendance_records
            WHERE session_id = p_session_id AND student_id = v_student_id
        ) THEN
            RETURN json_build_object('success', true, 'message', 'Attendance already marked for this session.');
        ELSIF NOT EXISTS (
            SELECT 1 FROM public.attendance_sessions WHERE id = p_session_id AND is_active = true
        ) THEN
            RETURN json_build_object('success', false, 'message', 'This lecture session just ended. Attendance could not be recorded.');
        ELSE
            RETURN json_build_object('success', false, 'message',
                'You are no longer enrolled in this division. Please contact your class teacher.');
        END IF;
    END IF;

    RETURN json_build_object('success', true, 'message', 'Attendance marked successfully!');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions;

-- 5-arg bridge: keeps an older deployed frontend working between the DB patch
-- and the next Vercel deploy. It delegates with unknown accuracy (0 credit).
CREATE OR REPLACE FUNCTION public.mark_attendance(
    p_session_id UUID,
    p_token VARCHAR,
    p_device_info TEXT DEFAULT NULL,
    p_lat FLOAT DEFAULT NULL,
    p_lng FLOAT DEFAULT NULL
)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
    SELECT public.mark_attendance(p_session_id, p_token, p_device_info, p_lat, p_lng, NULL::float);
$$;

REVOKE ALL ON FUNCTION public.mark_attendance(UUID, VARCHAR, TEXT, FLOAT, FLOAT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.mark_attendance(UUID, VARCHAR, TEXT, FLOAT, FLOAT, FLOAT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_attendance(UUID, VARCHAR, TEXT, FLOAT, FLOAT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.mark_attendance(UUID, VARCHAR, TEXT, FLOAT, FLOAT, FLOAT) TO authenticated, service_role;


-- =========================================================================
-- G) is_student_in_scope — ACTIVE enrollments only
-- =========================================================================
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS sig
        FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'public' AND p.proname = 'is_student_in_scope'
    LOOP
        EXECUTE format('DROP FUNCTION %s', r.sig);
    END LOOP;
END $$;

CREATE FUNCTION public.is_student_in_scope(p_student_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.users me
        WHERE me.id = auth.uid()
          AND (
                me.role = 'super_admin'
                OR (me.role = 'principal' AND EXISTS (
                        SELECT 1 FROM public.users s
                        WHERE s.id = p_student_id AND s.college_id = me.college_id))
                OR (me.role = 'hod' AND EXISTS (
                        SELECT 1 FROM public.users s
                        WHERE s.id = p_student_id AND s.department_id = me.department_id))
                OR (me.role IN ('class_teacher', 'faculty') AND (
                        EXISTS (
                            SELECT 1 FROM public.classes c
                            JOIN public.enrollments e ON e.class_id = c.id
                            WHERE c.class_teacher_id = me.id AND e.student_id = p_student_id
                              AND e.active IS TRUE)
                        OR EXISTS (
                            SELECT 1 FROM public.timetable t
                            JOIN public.enrollments e ON e.class_id = t.class_id
                            WHERE t.faculty_id = me.id AND e.student_id = p_student_id
                              AND e.active IS TRUE)))
              )
    );
$$;

REVOKE ALL ON FUNCTION public.is_student_in_scope(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_student_in_scope(UUID) TO authenticated, service_role;


-- =========================================================================
-- H1) Stats RPCs — enrollment WINDOW (only sessions while enrolled) and
--     attendance ledger semantics (present/late count; absent doesn't).
--     Same signatures as schema_security_repair.sql; scope checks unchanged
--     apart from active-enrollment awareness.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.get_student_attendance_stats(p_student_id UUID)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_role public.user_role;
    v_uid UUID := auth.uid();
    v_total BIGINT := 0;
    v_attended BIGINT := 0;
BEGIN
    IF p_student_id IS NULL OR v_uid IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT role INTO v_role FROM public.users WHERE id = v_uid;

    IF NOT (
        p_student_id = v_uid
        OR v_role = 'super_admin'
        OR (v_role = 'principal' AND EXISTS (
                SELECT 1 FROM public.users s
                WHERE s.id = p_student_id
                  AND s.college_id = public.get_user_college_id()))
        OR (v_role = 'hod' AND EXISTS (
                SELECT 1 FROM public.users s
                WHERE s.id = p_student_id
                  AND s.department_id = public.get_user_department_id()))
        OR (v_role = 'class_teacher' AND EXISTS (
                SELECT 1 FROM public.enrollments e
                JOIN public.classes c ON e.class_id = c.id
                WHERE e.student_id = p_student_id AND c.class_teacher_id = v_uid))
        OR (v_role = 'faculty' AND EXISTS (
                SELECT 1 FROM public.timetable t
                JOIN public.enrollments e ON e.class_id = t.class_id
                WHERE t.faculty_id = v_uid AND e.student_id = p_student_id))
    ) THEN
        RETURN NULL;
    END IF;

    -- A session counts toward a student only while they were enrolled in
    -- that class (enrollment window: created_at .. ended_at).
    SELECT
        COUNT(DISTINCT s.id),
        COUNT(DISTINCT r.session_id)
    INTO v_total, v_attended
    FROM public.enrollments e
    JOIN public.classes c ON c.id = e.class_id
    JOIN public.attendance_sessions s
         ON s.class_id = c.id
        AND s.created_at >= e.created_at
        AND s.created_at <= COALESCE(e.ended_at, 'infinity'::timestamptz)
    LEFT JOIN public.attendance_records r
         ON r.session_id = s.id
        AND r.student_id = e.student_id
        AND r.status <> 'absent'
    WHERE e.student_id = p_student_id
      AND e.active IS TRUE;

    RETURN json_build_object(
        'student_id', p_student_id,
        'total_sessions', v_total,
        'attended_sessions', v_attended,
        'attendance_percentage',
            CASE WHEN v_total > 0
                 THEN ROUND((v_attended::numeric / v_total::numeric) * 100, 2)
                 ELSE 0
            END
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_subject_attendance_stats(p_student_id UUID)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_role public.user_role;
    v_uid UUID := auth.uid();
    v_result JSON;
BEGIN
    IF p_student_id IS NULL OR v_uid IS NULL THEN
        RETURN '[]'::json;
    END IF;

    SELECT role INTO v_role FROM public.users WHERE id = v_uid;

    IF NOT (
        p_student_id = v_uid
        OR v_role = 'super_admin'
        OR (v_role = 'principal' AND EXISTS (
                SELECT 1 FROM public.users s
                WHERE s.id = p_student_id
                  AND s.college_id = public.get_user_college_id()))
        OR (v_role = 'hod' AND EXISTS (
                SELECT 1 FROM public.users s
                WHERE s.id = p_student_id
                  AND s.department_id = public.get_user_department_id()))
        OR (v_role = 'class_teacher' AND EXISTS (
                SELECT 1 FROM public.enrollments e
                JOIN public.classes c ON e.class_id = c.id
                WHERE e.student_id = p_student_id AND c.class_teacher_id = v_uid))
        OR (v_role = 'faculty' AND EXISTS (
                SELECT 1 FROM public.timetable t
                JOIN public.enrollments e ON e.class_id = t.class_id
                WHERE t.faculty_id = v_uid AND e.student_id = p_student_id))
    ) THEN
        RETURN '[]'::json;
    END IF;

    SELECT COALESCE(json_agg(row_to_json(stats)), '[]'::json) INTO v_result
    FROM (
        SELECT
            sub.id AS subject_id,
            sub.name AS subject_name,
            sub.code AS subject_code,
            COUNT(DISTINCT s.id) AS total_sessions,
            COUNT(DISTINCT r.session_id) AS attended_sessions,
            CASE WHEN COUNT(DISTINCT s.id) > 0
                 THEN ROUND((COUNT(DISTINCT r.session_id)::numeric / COUNT(DISTINCT s.id)::numeric) * 100, 2)
                 ELSE 0
            END AS attendance_percentage
        FROM public.enrollments e
        JOIN public.classes c ON c.id = e.class_id
        JOIN public.timetable t ON t.class_id = c.id
        JOIN public.subjects sub ON t.subject_id = sub.id
        LEFT JOIN public.attendance_sessions s
             ON s.timetable_id = t.id
            AND s.created_at >= e.created_at
            AND s.created_at <= COALESCE(e.ended_at, 'infinity'::timestamptz)
        LEFT JOIN public.attendance_records r
             ON r.session_id = s.id
            AND r.student_id = e.student_id
            AND r.status <> 'absent'
        WHERE e.student_id = p_student_id
          AND e.active IS TRUE
        GROUP BY sub.id, sub.name, sub.code
    ) stats;

    RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_student_attendance_stats(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_subject_attendance_stats(UUID) TO authenticated;


-- =========================================================================
-- H2) get_faculty_defaulters — LIVE, active enrollments, enrollment window
-- =========================================================================
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS sig
        FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'public' AND p.proname = 'get_faculty_defaulters'
    LOOP
        EXECUTE format('DROP FUNCTION %s', r.sig);
    END LOOP;
END $$;

CREATE FUNCTION public.get_faculty_defaulters(p_threshold INT)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_result JSON;
BEGIN
    BEGIN
        PERFORM public.cleanup_expired_sessions();
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'cleanup_expired_sessions skipped: %', SQLERRM;
    END;

    SELECT json_agg(row_to_json(z)) INTO v_result
    FROM (
        SELECT *
        FROM (
            SELECT
                u.id            AS student_id,
                u.first_name    AS first_name,
                u.last_name     AS last_name,
                u.email         AS email,
                COUNT(r.session_id)::bigint AS attended_sessions,
                COUNT(s.id)::bigint         AS total_sessions,
                CASE WHEN COUNT(s.id) = 0 THEN NULL
                     ELSE ROUND(COUNT(r.session_id)::numeric * 100 / COUNT(s.id), 1)
                END AS attendance_percentage
            FROM public.enrollments e
            JOIN public.users u ON u.id = e.student_id
            JOIN public.attendance_sessions s
                 ON s.class_id = e.class_id
                AND s.created_at >= e.created_at
                AND s.created_at <= COALESCE(e.ended_at, 'infinity'::timestamptz)
            LEFT JOIN public.attendance_records r
                 ON r.session_id = s.id
                AND r.student_id = e.student_id
                AND r.status <> 'absent'
            WHERE u.role = 'student'
              AND e.active IS TRUE
              AND public.is_student_in_scope(u.id)
            GROUP BY u.id, u.first_name, u.last_name, u.email
        ) d
        WHERE d.attendance_percentage IS NOT NULL
          AND d.attendance_percentage < p_threshold
          AND d.total_sessions > 0
        ORDER BY d.attendance_percentage ASC
        LIMIT 100
    ) z;

    RETURN COALESCE(v_result, '[]'::json);
END;
$$;

REVOKE ALL ON FUNCTION public.get_faculty_defaulters(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_faculty_defaulters(INT) TO authenticated, service_role;


-- =========================================================================
-- H3) get_dashboard_stats — live defaulter count, enrollment window,
--     absent rows excluded from "attended", today's pct denominator now
--     honours the ledger (present+late count as attended).
-- =========================================================================
CREATE OR REPLACE FUNCTION public.get_dashboard_stats()
RETURNS json AS $$
DECLARE
    v_role user_role;
    v_college_id UUID;
    v_department_id UUID;

    v_total_students INTEGER;
    v_active_classes INTEGER;
    v_today_pct NUMERIC;
    v_low_count INTEGER;
    v_user_id UUID := auth.uid();

    result json;
BEGIN
    -- LAZY EVALUATION: auto-close expired sessions (+ absence ledger)
    PERFORM public.cleanup_expired_sessions();

    SELECT role, college_id, department_id INTO v_role, v_college_id, v_department_id
    FROM public.users WHERE id = v_user_id;

    -- Total Students (active enrollments only)
    SELECT COUNT(DISTINCT u.id) INTO v_total_students
    FROM public.users u
    JOIN public.enrollments e ON e.student_id = u.id AND e.active IS TRUE
    LEFT JOIN public.classes c ON e.class_id = c.id
    WHERE u.role = 'student'
      AND (v_role = 'super_admin' OR u.college_id = v_college_id)
      AND (v_role NOT IN ('hod', 'faculty', 'class_teacher') OR u.department_id = v_department_id)
      AND (v_role != 'class_teacher' OR c.class_teacher_id = v_user_id);

    -- Active Classes
    SELECT COUNT(*) INTO v_active_classes
    FROM public.classes c
    JOIN public.departments d ON c.department_id = d.id
    WHERE (v_role = 'super_admin' OR d.college_id = v_college_id)
      AND (v_role NOT IN ('hod', 'faculty', 'class_teacher') OR c.department_id = v_department_id)
      AND (v_role != 'class_teacher' OR c.class_teacher_id = v_user_id);

    -- Defaulters (Below 75%) — LIVE, enrollment window, active enrollments
    SELECT COUNT(DISTINCT d.student_id) INTO v_low_count
    FROM (
        SELECT
            u.id AS student_id,
            COUNT(s.id) AS total_sessions,
            CASE WHEN COUNT(s.id) = 0 THEN NULL
                 ELSE ROUND(COUNT(r.session_id)::numeric * 100 / COUNT(s.id), 1)
            END AS attendance_percentage
        FROM public.users u
        JOIN public.enrollments e ON e.student_id = u.id AND e.active IS TRUE
        JOIN public.classes c ON c.id = e.class_id
        JOIN public.attendance_sessions s
             ON s.class_id = e.class_id
            AND s.created_at >= e.created_at
            AND s.created_at <= COALESCE(e.ended_at, 'infinity'::timestamptz)
        LEFT JOIN public.attendance_records r
             ON r.session_id = s.id
            AND r.student_id = e.student_id
            AND r.status <> 'absent'
        WHERE u.role = 'student'
          AND (v_role = 'super_admin' OR u.college_id = v_college_id)
          AND (v_role NOT IN ('hod', 'faculty', 'class_teacher') OR u.department_id = v_department_id)
          AND (v_role != 'class_teacher' OR c.class_teacher_id = v_user_id)
        GROUP BY u.id
    ) d
    WHERE d.attendance_percentage IS NOT NULL
      AND d.attendance_percentage < 75
      AND d.total_sessions > 0;

    -- Today's Attendance Pct — with the ledger, present+late count as attended
    WITH today_scans AS (
        SELECT r.status
        FROM public.attendance_records r
        JOIN public.users u ON r.student_id = u.id
        LEFT JOIN public.enrollments e ON e.student_id = u.id AND e.active IS TRUE
        LEFT JOIN public.classes c ON e.class_id = c.id
        WHERE DATE(r.scanned_at AT TIME ZONE 'UTC') = CURRENT_DATE
          AND (v_role = 'super_admin' OR u.college_id = v_college_id)
          AND (v_role NOT IN ('hod', 'faculty', 'class_teacher') OR u.department_id = v_department_id)
          AND (v_role != 'class_teacher' OR c.class_teacher_id = v_user_id)
    )
    SELECT
        CASE
            WHEN COUNT(*) = 0 THEN 0
            ELSE ROUND((SUM(CASE WHEN status <> 'absent' THEN 1 ELSE 0 END)::NUMERIC / COUNT(*)) * 100, 1)
        END INTO v_today_pct
    FROM today_scans;

    result := json_build_object(
        'totalStudents', COALESCE(v_total_students, 0),
        'activeClasses', COALESCE(v_active_classes, 0),
        'todayAttendancePct', COALESCE(v_today_pct, 0),
        'lowAttendanceCount', COALESCE(v_low_count, 0)
    );

    RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions;

REVOKE ALL ON FUNCTION public.get_dashboard_stats() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_dashboard_stats() TO authenticated, service_role;


-- =========================================================================
-- H4) Reporting summaries — active + historical enrollments with WINDOW
--     clamps (a session only counts into a student's own denominator while
--     they were enrolled). Classes stay listed for their report window even
--     if enrollments were since closed (history preserved).
-- =========================================================================
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS sig
        FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'public'
          AND p.proname IN ('get_department_attendance_summary',
                            'get_subject_attendance_summary',
                            'get_monthly_attendance_log')
    LOOP
        EXECUTE format('DROP FUNCTION %s', r.sig);
    END LOOP;
END $$;

CREATE FUNCTION public.get_department_attendance_summary(
    p_from DATE DEFAULT NULL,
    p_to   DATE DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_from   DATE := COALESCE(p_from, (CURRENT_DATE - INTERVAL '6 months')::date);
    v_to     DATE := COALESCE(p_to, CURRENT_DATE);
    v_result JSON;
BEGIN
    SELECT COALESCE(json_agg(row_to_json(r) ORDER BY r.department_name), '[]'::json)
      INTO v_result
    FROM (
        WITH scoped AS (
            SELECT u.id AS student_id
            FROM public.users u
            WHERE u.role = 'student'
              AND public.is_student_in_scope(u.id)
        ),
        -- Current enrollments plus historical ones that existed during the
        -- report window (ended_at >= v_from keeps them for the period).
        scoped_enrollments AS (
            SELECT e.student_id, e.class_id, c.department_id,
                   e.created_at, e.ended_at
            FROM public.enrollments e
            JOIN public.classes c ON c.id = e.class_id
            WHERE e.student_id IN (SELECT student_id FROM scoped)
              AND (e.active IS TRUE OR COALESCE(e.ended_at::date, v_from) >= v_from)
        ),
        sess AS (
            SELECT s.id AS session_id,
                   COALESCE(s.class_id, t.class_id) AS class_id,
                   s.created_at AS session_ts,
                   COALESCE(s.date, s.created_at::date) AS session_date
            FROM public.attendance_sessions s
            LEFT JOIN public.timetable t ON t.id = s.timetable_id
            WHERE COALESCE(s.date, s.created_at::date) BETWEEN v_from AND v_to
        ),
        per_student AS (
            SELECT se.department_id,
                   se.student_id,
                   COUNT(DISTINCT ss.session_id) AS total_sessions,
                   COUNT(DISTINCT ar.session_id) AS attended
            FROM scoped_enrollments se
            LEFT JOIN sess ss ON ss.class_id = se.class_id
                 -- enrollment window clamp
                 AND ss.session_ts >= se.created_at
                 AND ss.session_ts <= COALESCE(se.ended_at, 'infinity'::timestamptz)
            LEFT JOIN public.attendance_records ar
                   ON ar.session_id = ss.session_id
                  AND ar.student_id = se.student_id
                  AND ar.status <> 'absent'
            GROUP BY se.department_id, se.student_id
        ),
        dept_students AS (
            SELECT p.department_id,
                   COUNT(*)                        AS students,
                   SUM(p.total_sessions)           AS expected,
                   SUM(p.attended)                 AS attendances,
                   AVG(CASE WHEN p.total_sessions > 0
                            THEN (p.attended::numeric / p.total_sessions) * 100
                            ELSE NULL END)         AS avg_student_pct
            FROM per_student p
            GROUP BY p.department_id
        ),
        dept_lectures AS (
            SELECT c.department_id, COUNT(DISTINCT ss.session_id) AS lectures_held
            FROM sess ss
            JOIN public.classes c ON c.id = ss.class_id
            WHERE ss.class_id IN (SELECT class_id FROM scoped_enrollments)
            GROUP BY c.department_id
        )
        SELECT
            d.id                                AS department_id,
            d.name::text                        AS department_name,
            COALESCE(ds.students, 0)            AS students,
            COALESCE(dl.lectures_held, 0)       AS lectures_held,
            COALESCE(ds.attendances, 0)         AS attendances,
            COALESCE(ds.expected, 0)            AS expected,
            CASE WHEN COALESCE(ds.expected, 0) > 0
                 THEN ROUND((ds.attendances::numeric / ds.expected) * 100, 1)
                 ELSE 0 END                     AS attendance_pct,
            COALESCE(ROUND(ds.avg_student_pct, 1), 0) AS avg_student_pct
        FROM public.departments d
        LEFT JOIN dept_students  ds ON ds.department_id = d.id
        LEFT JOIN dept_lectures dl ON dl.department_id = d.id
        WHERE ds.department_id IS NOT NULL OR dl.department_id IS NOT NULL
        ORDER BY d.name
    ) r;

    RETURN v_result;
END;
$$;

CREATE FUNCTION public.get_subject_attendance_summary(
    p_from DATE DEFAULT NULL,
    p_to   DATE DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_from   DATE := COALESCE(p_from, (CURRENT_DATE - INTERVAL '6 months')::date);
    v_to     DATE := COALESCE(p_to, CURRENT_DATE);
    v_result JSON;
BEGIN
    SELECT COALESCE(json_agg(row_to_json(r) ORDER BY r.department_name, r.subject_code), '[]'::json)
      INTO v_result
    FROM (
        WITH scoped AS (
            SELECT u.id AS student_id
            FROM public.users u
            WHERE u.role = 'student'
              AND public.is_student_in_scope(u.id)
        ),
        scoped_enrollments AS (
            SELECT e.student_id, e.class_id, e.created_at, e.ended_at
            FROM public.enrollments e
            WHERE e.student_id IN (SELECT student_id FROM scoped)
              AND (e.active IS TRUE OR COALESCE(e.ended_at::date, v_from) >= v_from)
        ),
        sess AS (
            SELECT s.id AS session_id,
                   COALESCE(s.class_id,   t.class_id)   AS class_id,
                   COALESCE(s.subject_id, t.subject_id) AS subject_id,
                   s.created_at AS session_ts,
                   COALESCE(s.date, s.created_at::date) AS session_date
            FROM public.attendance_sessions s
            LEFT JOIN public.timetable t ON t.id = s.timetable_id
            WHERE COALESCE(s.date, s.created_at::date) BETWEEN v_from AND v_to
        ),
        subject_of_class AS (
            SELECT DISTINCT t.class_id, t.subject_id
            FROM public.timetable t
            WHERE t.subject_id IS NOT NULL
              AND t.class_id IN (SELECT class_id FROM scoped_enrollments)
            UNION
            SELECT DISTINCT ss.class_id, ss.subject_id
            FROM sess ss
            WHERE ss.subject_id IS NOT NULL
              AND ss.class_id IN (SELECT class_id FROM scoped_enrollments)
        ),
        per_student AS (
            SELECT soc.subject_id,
                   se.student_id,
                   COUNT(DISTINCT ss.session_id) AS total_sessions,
                   COUNT(DISTINCT ar.session_id) AS attended
            FROM scoped_enrollments se
            JOIN subject_of_class soc ON soc.class_id = se.class_id
            LEFT JOIN sess ss
                   ON ss.class_id = se.class_id
                  AND ss.subject_id = soc.subject_id
                 -- enrollment window clamp
                  AND ss.session_ts >= se.created_at
                  AND ss.session_ts <= COALESCE(se.ended_at, 'infinity'::timestamptz)
            LEFT JOIN public.attendance_records ar
                   ON ar.session_id = ss.session_id
                  AND ar.student_id = se.student_id
                  AND ar.status <> 'absent'
            GROUP BY soc.subject_id, se.student_id
        ),
        subject_students AS (
            SELECT p.subject_id,
                   COUNT(*)                  AS students,
                   SUM(p.total_sessions)     AS expected,
                   SUM(p.attended)           AS attendances,
                   AVG(CASE WHEN p.total_sessions > 0
                            THEN (p.attended::numeric / p.total_sessions) * 100
                            ELSE NULL END)   AS avg_student_pct
            FROM per_student p
            GROUP BY p.subject_id
        ),
        subject_lectures AS (
            SELECT ss.subject_id, COUNT(DISTINCT ss.session_id) AS lectures_held
            FROM sess ss
            WHERE ss.subject_id IS NOT NULL
              AND ss.class_id IN (SELECT class_id FROM scoped_enrollments)
            GROUP BY ss.subject_id
        )
        SELECT
            sub.id                              AS subject_id,
            sub.code::text                      AS subject_code,
            sub.name::text                      AS subject_name,
            COALESCE(d.name, 'Unassigned')::text AS department_name,
            COALESCE(sstu.students, 0)          AS students,
            COALESCE(slec.lectures_held, 0)     AS lectures_held,
            COALESCE(sstu.attendances, 0)       AS attendances,
            COALESCE(sstu.expected, 0)          AS expected,
            CASE WHEN COALESCE(sstu.expected, 0) > 0
                 THEN ROUND((sstu.attendances::numeric / sstu.expected) * 100, 1)
                 ELSE 0 END                     AS attendance_pct,
            COALESCE(ROUND(sstu.avg_student_pct, 1), 0) AS avg_student_pct
        FROM public.subjects sub
        JOIN subject_students sstu ON sstu.subject_id = sub.id
        LEFT JOIN subject_lectures slec ON slec.subject_id = sub.id
        LEFT JOIN public.departments d  ON d.id = sub.department_id
        ORDER BY d.name, sub.code
    ) r;

    RETURN v_result;
END;
$$;

CREATE FUNCTION public.get_monthly_attendance_log(
    p_from DATE DEFAULT NULL,
    p_to   DATE DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_from   DATE := COALESCE(p_from, (CURRENT_DATE - INTERVAL '6 months')::date);
    v_to     DATE := COALESCE(p_to, CURRENT_DATE);
    v_result JSON;
BEGIN
    SELECT COALESCE(json_agg(row_to_json(r) ORDER BY r.month_start DESC), '[]'::json)
      INTO v_result
    FROM (
        WITH scoped AS (
            SELECT u.id AS student_id
            FROM public.users u
            WHERE u.role = 'student'
              AND public.is_student_in_scope(u.id)
        ),
        scoped_enrollments AS (
            SELECT e.student_id, e.class_id, e.created_at, e.ended_at
            FROM public.enrollments e
            WHERE e.student_id IN (SELECT student_id FROM scoped)
              AND (e.active IS TRUE OR COALESCE(e.ended_at::date, v_from) >= v_from)
        ),
        sess AS (
            SELECT s.id AS session_id,
                   COALESCE(s.class_id, t.class_id) AS class_id,
                   date_trunc('month', COALESCE(s.date, s.created_at::date)) AS month_start,
                   s.created_at AS session_ts
            FROM public.attendance_sessions s
            LEFT JOIN public.timetable t ON t.id = s.timetable_id
            WHERE COALESCE(s.date, s.created_at::date) BETWEEN v_from AND v_to
        ),
        per_student_month AS (
            SELECT ss.month_start,
                   se.student_id,
                   COUNT(DISTINCT ss.session_id) AS total_sessions,
                   COUNT(DISTINCT ar.session_id) AS attended
            FROM scoped_enrollments se
            JOIN sess ss ON ss.class_id = se.class_id
                 -- enrollment window clamp
                 AND ss.session_ts >= se.created_at
                 AND ss.session_ts <= COALESCE(se.ended_at, 'infinity'::timestamptz)
            LEFT JOIN public.attendance_records ar
                   ON ar.session_id = ss.session_id
                  AND ar.student_id = se.student_id
                  AND ar.status <> 'absent'
            GROUP BY ss.month_start, se.student_id
        ),
        month_stats AS (
            SELECT p.month_start,
                   COUNT(DISTINCT p.student_id) AS students,
                   SUM(p.total_sessions)        AS expected,
                   SUM(p.attended)              AS attendances,
                   AVG(CASE WHEN p.total_sessions > 0
                            THEN (p.attended::numeric / p.total_sessions) * 100
                            ELSE NULL END)      AS avg_student_pct
            FROM per_student_month p
            GROUP BY p.month_start
        ),
        month_lectures AS (
            SELECT ss.month_start, COUNT(DISTINCT ss.session_id) AS lectures_held
            FROM sess ss
            WHERE ss.class_id IN (SELECT class_id FROM scoped_enrollments)
            GROUP BY ss.month_start
        )
        SELECT
            ml.month_start::date                     AS month_start,
            to_char(ml.month_start, 'Mon YYYY')      AS month_label,
            COALESCE(ms.students, 0)                 AS students,
            ml.lectures_held                         AS lectures_held,
            COALESCE(ms.attendances, 0)              AS attendances,
            COALESCE(ms.expected, 0)                 AS expected,
            CASE WHEN COALESCE(ms.expected, 0) > 0
                 THEN ROUND((ms.attendances::numeric / ms.expected) * 100, 1)
                 ELSE 0 END                          AS attendance_pct,
            COALESCE(ROUND(ms.avg_student_pct, 1), 0) AS avg_student_pct
        FROM month_lectures ml
        LEFT JOIN month_stats ms ON ms.month_start = ml.month_start
        ORDER BY ml.month_start DESC
    ) r;

    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_department_attendance_summary(DATE, DATE) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_subject_attendance_summary(DATE, DATE) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_monthly_attendance_log(DATE, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_department_attendance_summary(DATE, DATE) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_subject_attendance_summary(DATE, DATE) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_monthly_attendance_log(DATE, DATE) TO authenticated, service_role;


-- =========================================================================
-- H5) get_user_hierarchy — enrollments payload becomes ACTIVE-ONLY so the
--     user tree can never attach a student to a stale (closed) class.
--     Body is otherwise byte-identical to schema_tree_rpc.sql.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.get_user_hierarchy()
RETURNS json AS $$
DECLARE
    caller_role public.user_role;
    caller_college_id UUID;
    caller_dept_id UUID;
    caller_id UUID;
    result json;
BEGIN
    caller_role := public.get_user_role();
    caller_college_id := public.get_user_college_id();
    caller_dept_id := public.get_user_department_id();
    caller_id := auth.uid();

    -- Check if user is authenticated
    IF caller_role IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    -- Return JSON built by queries
    -- For simplicity and performance, we'll return flat lists of all entities the user is allowed to see,
    -- and let the frontend build the Tree UI. This is much faster and more flexible for UI state.

    RETURN json_build_object(
        'users', (
            SELECT COALESCE(json_agg(
                json_build_object(
                    'id', u.id,
                    'first_name', u.first_name,
                    'last_name', u.last_name,
                    'email', u.email,
                    'role', u.role,
                    'college_id', u.college_id,
                    'department_id', u.department_id,
                    'college_name', c.name,
                    'department_name', d.name
                )
            ), '[]'::json)
            FROM public.users u
            LEFT JOIN public.colleges c ON u.college_id = c.id
            LEFT JOIN public.departments d ON u.department_id = d.id
            WHERE 
                (caller_role = 'super_admin') OR
                (caller_role = 'principal' AND u.college_id = caller_college_id) OR
                (caller_role = 'hod' AND u.college_id = caller_college_id AND u.department_id = caller_dept_id) OR
                (caller_role = 'class_teacher' AND u.college_id = caller_college_id AND u.department_id = caller_dept_id) OR
                (caller_role = 'faculty' AND u.college_id = caller_college_id AND u.department_id = caller_dept_id)
        ),
        'classes', (
            SELECT COALESCE(json_agg(
                json_build_object(
                    'id', cls.id,
                    'name', cls.name,
                    'semester', cls.semester,
                    'department_id', cls.department_id,
                    'class_teacher_id', cls.class_teacher_id
                )
            ), '[]'::json)
            FROM public.classes cls
            JOIN public.departments d ON cls.department_id = d.id
            WHERE 
                (caller_role = 'super_admin') OR
                (caller_role = 'principal' AND d.college_id = caller_college_id) OR
                (caller_role IN ('hod', 'class_teacher', 'faculty') AND cls.department_id = caller_dept_id)
        ),
        'enrollments', (
            SELECT COALESCE(json_agg(
                json_build_object(
                    'student_id', e.student_id,
                    'class_id', e.class_id,
                    'roll_number', e.roll_number,
                    'active', e.active
                )
            ), '[]'::json)
            FROM public.enrollments e
            JOIN public.classes cls ON e.class_id = cls.id
            JOIN public.departments d ON cls.department_id = d.id
            WHERE e.active IS TRUE
              AND (
                (caller_role = 'super_admin') OR
                (caller_role = 'principal' AND d.college_id = caller_college_id) OR
                (caller_role IN ('hod', 'class_teacher', 'faculty') AND cls.department_id = caller_dept_id)
            )
        ),
        'timetable', (
            SELECT COALESCE(json_agg(
                json_build_object(
                    'faculty_id', t.faculty_id,
                    'class_id', t.class_id,
                    'subject_name', s.name
                )
            ), '[]'::json)
            FROM public.timetable t
            JOIN public.classes cls ON t.class_id = cls.id
            JOIN public.subjects s ON t.subject_id = s.id
            JOIN public.departments d ON cls.department_id = d.id
            WHERE 
                (caller_role = 'super_admin') OR
                (caller_role = 'principal' AND d.college_id = caller_college_id) OR
                (caller_role IN ('hod', 'class_teacher', 'faculty') AND cls.department_id = caller_dept_id)
        )
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- =========================================================================
-- I) get_recent_scans — the live feed must not show ledger-only ABSENT rows
--    (those appear in reports/exports, not the realtime feed).
-- =========================================================================
CREATE OR REPLACE FUNCTION public.get_recent_scans()
RETURNS TABLE (
    id UUID,
    student_name TEXT,
    subject_name VARCHAR(255),
    status public.attendance_status,
    scanned_at TIMESTAMPTZ
) AS $$
DECLARE
    v_role user_role;
    v_college_id UUID;
    v_department_id UUID;
BEGIN
    SELECT role, college_id, department_id INTO v_role, v_college_id, v_department_id
    FROM public.users WHERE users.id = auth.uid();

    IF v_role NOT IN ('super_admin', 'principal', 'hod') THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        r.id,
        (u.first_name || ' ' || u.last_name) AS student_name,
        COALESCE(sub.name, 'Ad-Hoc Session'::VARCHAR(255)) AS subject_name,
        r.status,
        r.scanned_at
    FROM public.attendance_records r
    JOIN public.users u ON r.student_id = u.id
    JOIN public.attendance_sessions s ON r.session_id = s.id
    LEFT JOIN public.timetable t ON s.timetable_id = t.id
    LEFT JOIN public.subjects sub ON COALESCE(t.subject_id, s.subject_id) = sub.id
    WHERE r.status <> 'absent'
      AND (v_role = 'super_admin' OR u.college_id = v_college_id)
      AND (v_role != 'hod' OR u.department_id = v_department_id)
    ORDER BY r.scanned_at DESC
    LIMIT 10;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions;

REVOKE ALL ON FUNCTION public.get_recent_scans() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_recent_scans() TO authenticated, service_role;

-- useUsers (frontend admin pages) reads enrollments nested; PostgREST needs
-- the two new columns visible — no extra grant needed (RLS by policy), but
-- make ANALYZE cheap for the new index after backfill.
ANALYZE public.enrollments;
ANALYZE public.attendance_sessions;

-- =========================================================================
-- Reload PostgREST schema cache
-- =========================================================================
NOTIFY pgrst, 'reload schema';

