-- =========================================================================
-- SCHEMA BUG-FIX PASS (live-DB patch, fully re-runnable)
-- File: supabase/schema_bugfix_pass.sql
--
-- Run this whole file, top to bottom, in the Supabase SQL editor (after the
-- existing chain, especially schema_security_repair.sql). It is safe to
-- re-run — every statement is guarded or drop-first.
--
-- Fixes (6):
--  1) enrollments.updated_at  — column was missing but enroll_student writes
--     it -> "column enrollments.updated_at does not exist" on every
--     re-enrollment conflict.
--  2) Device anti-proxy enforcement in mark_attendance — the spec requires
--     device fingerprinting; previously p_device_info was stored but never
--     checked, so one phone could mark unlimited students in a session.
--  3) get_faculty_defaulters is now computed LIVE from
--     enrollments/sessions/records (no more materialized-view lag), with the
--     existing is_student_in_scope(UID) scoping preserved.
--  4) get_dashboard_stats defaulter count is now LIVE too; the stale
--     materialized view + its refresh triggers are retired.
--  5) get_faculty_audit_report: dept_admin was seeing the whole COLLEGE;
--     now dept-scoped (like hod). Also adds search_path hardening.
--  6) get_recent_scans: adds a role gate (was callable by any authenticated
--     user, including students/faculty) + search_path hardening.
-- =========================================================================


-- =========================================================================
-- 0) Remove drift-risk leftovers of mark_attendance (the ungated 3-arg
--    overload must never come back), then leave the 5-arg one alone here
--    — it is replaced in full below.
-- =========================================================================
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS sig
        FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'public'
          AND p.proname = 'mark_attendance'
          -- to_regprocedure() returns NULL (not an error) if a signature is unknown
          AND p.oid::regprocedure <> to_regprocedure('public.mark_attendance(uuid,varchar,text,float,float)')
    LOOP
        EXECUTE format('DROP FUNCTION %s', r.sig);
        RAISE NOTICE 'Dropped drifted mark_attendance overload: %', r.sig;
    END LOOP;
END $$;


-- =========================================================================
-- 1) enrollments.updated_at — the column enroll_student() writes
-- =========================================================================
ALTER TABLE public.enrollments
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();


-- =========================================================================
-- 2) mark_attendance — device anti-proxy enforcement + clearer conflict
--    messages. Same signature (5-arg), so CREATE OR REPLACE is safe.
--
--    device_info format (sent by Scanner.tsx): "<deviceToken>|<userAgent>|
--    <WxH>|<colorDepth>|<cores>". The first segment is the stable device
--    token persisted in localStorage.
--
--    Anti-proxy rules implemented:
--      a) Pre-check: another student already used this device token in this
--         session -> reject.
--      b) Insert uses ON CONFLICT DO NOTHING *without* a conflict target so
--         it also falls back on the (optional) device unique index created
--         below, then GET DIAGNOSTICS disambiguates: "already marked for
--         yourself" (success) vs "device used by someone else" (reject).
-- =========================================================================
CREATE OR REPLACE FUNCTION public.mark_attendance(
    p_session_id UUID,
    p_token VARCHAR,
    p_device_info TEXT DEFAULT NULL,
    p_lat FLOAT DEFAULT NULL,
    p_lng FLOAT DEFAULT NULL
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
        -- Best-effort cleanup: session expiry is also enforced below, so a
        -- missing OR broken cleanup function must never abort the scan.
        RAISE NOTICE 'cleanup_expired_sessions skipped: %', SQLERRM;
    END;

    SELECT * INTO v_session
    FROM public.attendance_sessions
    WHERE id = p_session_id AND is_active = true;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'message', 'Session is not active or does not exist.');
    END IF;

    IF v_session.expires_at IS NOT NULL AND NOW() > v_session.expires_at THEN
        UPDATE public.attendance_sessions SET is_active = false WHERE id = p_session_id;
        RETURN json_build_object('success', false, 'message', 'This lecture session has ended.');
    END IF;

    -- Rotating QR token (TOTP window +/- 1 == ~30s validity)
    v_window := floor(extract(epoch FROM now()) / 10);

    -- ::text keeps this working whether the column is uuid (some deployments)
    -- or text, and the frontend hashes the same string PostgREST returns.
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

    -- DIVISION GATE: only students assigned to this session's division may
    -- scan its QR. Distinguish the two failure causes so the student gets an
    -- actionable message.
    IF NOT EXISTS (
        SELECT 1 FROM public.enrollments
        WHERE student_id = v_student_id AND class_id = v_class_id
    ) THEN
        IF EXISTS (
            SELECT 1 FROM public.enrollments WHERE student_id = v_student_id
        ) THEN
            RETURN json_build_object('success', false, 'message',
                'This QR code belongs to a different division. Only students of this division can mark attendance for this lecture.');
        ELSE
            RETURN json_build_object('success', false, 'message',
                'You are not assigned to any division yet. Please contact your administrator.');
        END IF;
    END IF;

    -- DEVICE ANTI-PROXY GATE: the same physical device may only mark ONE
    -- student per session. Forget your own earlier row here — for yourself
    -- the ON CONFLICT below produces the friendly "already marked" reply.
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

    -- Geofence against the classroom location
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

    IF v_distance > 100.0 THEN
        RETURN json_build_object('success', false, 'message', 'You are ' || round(v_distance::numeric, 1) || ' meters away. You must be within 100 meters of the classroom.');
    END IF;

    -- Race-safe insert: no conflict target means BOTH the historical
    -- UNIQUE(session_id, student_id) index AND the device-token index below
    -- are enforced atomically in one step; concurrent duplicate scans can
    -- never create duplicate rows.
    INSERT INTO public.attendance_records (session_id, student_id, status, device_info)
    VALUES (p_session_id, v_student_id, 'present', p_device_info)
    ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    IF v_inserted = 0 THEN
        IF EXISTS (
            SELECT 1 FROM public.attendance_records
            WHERE session_id = p_session_id AND student_id = v_student_id
        ) THEN
            RETURN json_build_object('success', true, 'message', 'Attendance already marked for this session.');
        ELSE
            RETURN json_build_object('success', false, 'message',
                'This device has already marked attendance for another student in this session.');
        END IF;
    END IF;

    RETURN json_build_object('success', true, 'message', 'Attendance marked successfully!');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions;

-- Optional race-proof backstop: a partial UNIQUE index on
-- (session_id, device_token) so even two truly concurrent scans for two
-- different students from the same device cannot both insert.
-- If the live table already contains such duplicate pairs, the index cannot
-- be created — we NOTICE that instead of aborting (re-runnable either way).
DO $$
DECLARE
    v_groups BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_groups
    FROM (
        SELECT session_id, split_part(device_info, '|', 1) AS dev
        FROM public.attendance_records
        WHERE device_info IS NOT NULL AND length(trim(device_info)) > 0
        GROUP BY session_id, split_part(device_info, '|', 1)
        HAVING COUNT(*) > 1 AND COUNT(DISTINCT student_id) > 1
    ) x;

    IF v_groups > 0 THEN
        RAISE NOTICE 'Device enforcement index NOT created: % session(s) already contain the same device used by multiple students (pre-existing proxy rows). Deduplicate those rows and re-run this file to enable the hard server-side guard.', v_groups;
    ELSE
        CREATE UNIQUE INDEX IF NOT EXISTS uq_attendance_records_device_session
            ON public.attendance_records (session_id, (split_part(device_info, '|', 1)))
            WHERE device_info IS NOT NULL AND length(trim(device_info)) > 0;
        RAISE NOTICE 'Device enforcement index uq_attendance_records_device_session created.';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Could not create device enforcement index: %', SQLERRM;
END $$;

REVOKE ALL ON FUNCTION public.mark_attendance(UUID, VARCHAR, TEXT, FLOAT, FLOAT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_attendance(UUID, VARCHAR, TEXT, FLOAT, FLOAT) TO authenticated, service_role;


-- =========================================================================
-- 3) get_faculty_defaulters — LIVE computation (no materialized view), same
--    shape and scoping as before (is_student_in_scope), same column keys
--    the frontend expects.
-- =========================================================================
DO $$
DECLARE
    r RECORD;
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
                u.id                    AS student_id,
                u.first_name            AS first_name,
                u.last_name             AS last_name,
                u.email                 AS email,
                SUM(COALESCE(att.attended, 0))::bigint AS attended_sessions,
                SUM(COALESCE(sch.total,   0))::bigint AS total_sessions,
                CASE
                    WHEN SUM(COALESCE(sch.total, 0)) = 0 THEN NULL
                    ELSE ROUND(SUM(COALESCE(att.attended, 0))::numeric * 100 / SUM(sch.total), 1)
                END AS attendance_percentage
            FROM public.enrollments e
            JOIN public.users u ON u.id = e.student_id
            LEFT JOIN (
                SELECT s.class_id, COUNT(*) AS total
                FROM public.attendance_sessions s
                GROUP BY s.class_id
            ) sch ON sch.class_id = e.class_id
            LEFT JOIN (
                SELECT r.student_id, s.class_id, COUNT(*) AS attended
                FROM public.attendance_records r
                JOIN public.attendance_sessions s ON s.id = r.session_id
                GROUP BY r.student_id, s.class_id
            ) att ON att.student_id = e.student_id AND att.class_id = e.class_id
            WHERE u.role = 'student'
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
-- 4) get_dashboard_stats — replace the materialized-view defaulter count
--    with the same LIVE formula as (3), keeping lazy_eval's exact scoping
--    for the other three stats. Then retire the stale matview + triggers.
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
    -- LAZY EVALUATION: Auto-close any expired sessions
    PERFORM public.cleanup_expired_sessions();

    -- Get caller identity
    SELECT role, college_id, department_id INTO v_role, v_college_id, v_department_id
    FROM public.users WHERE id = v_user_id;

    -- Calculate Total Students
    SELECT COUNT(DISTINCT u.id) INTO v_total_students
    FROM public.users u
    LEFT JOIN public.enrollments e ON u.id = e.student_id
    LEFT JOIN public.classes c ON e.class_id = c.id
    WHERE u.role = 'student'
      AND (v_role = 'super_admin' OR u.college_id = v_college_id)
      AND (v_role NOT IN ('hod', 'faculty', 'class_teacher') OR u.department_id = v_department_id)
      AND (v_role != 'class_teacher' OR c.class_teacher_id = v_user_id);

    -- Calculate Active Classes
    SELECT COUNT(*) INTO v_active_classes
    FROM public.classes c
    JOIN public.departments d ON c.department_id = d.id
    WHERE (v_role = 'super_admin' OR d.college_id = v_college_id)
      AND (v_role NOT IN ('hod', 'faculty', 'class_teacher') OR c.department_id = v_department_id)
      AND (v_role != 'class_teacher' OR c.class_teacher_id = v_user_id);

    -- Calculate Defaulters (Below 75%) — LIVE from sessions/records
    SELECT COUNT(DISTINCT d.student_id) INTO v_low_count
    FROM (
        SELECT
            u.id AS student_id,
            SUM(COALESCE(sch.total, 0)) AS total_sessions,
            CASE
                WHEN SUM(COALESCE(sch.total, 0)) = 0 THEN NULL
                ELSE ROUND(SUM(COALESCE(att.attended, 0))::numeric * 100 / SUM(sch.total), 1)
            END AS attendance_percentage
        FROM public.users u
        JOIN public.enrollments e ON e.student_id = u.id
        JOIN public.classes c ON c.id = e.class_id
        LEFT JOIN (
            SELECT s.class_id, COUNT(*) AS total
            FROM public.attendance_sessions s
            GROUP BY s.class_id
        ) sch ON sch.class_id = e.class_id
        LEFT JOIN (
            SELECT r.student_id, s.class_id, COUNT(*) AS attended
            FROM public.attendance_records r
            JOIN public.attendance_sessions s ON s.id = r.session_id
            GROUP BY r.student_id, s.class_id
        ) att ON att.student_id = e.student_id AND att.class_id = e.class_id
        WHERE u.role = 'student'
          AND (v_role = 'super_admin' OR u.college_id = v_college_id)
          AND (v_role NOT IN ('hod', 'faculty', 'class_teacher') OR u.department_id = v_department_id)
          AND (v_role != 'class_teacher' OR c.class_teacher_id = v_user_id)
        GROUP BY u.id
    ) d
    WHERE d.attendance_percentage IS NOT NULL
      AND d.attendance_percentage < 75
      AND d.total_sessions > 0;

    -- Calculate Today's Attendance Pct
    WITH today_scans AS (
        SELECT r.status, r.student_id
        FROM public.attendance_records r
        JOIN public.users u ON r.student_id = u.id
        LEFT JOIN public.enrollments e ON u.id = e.student_id
        LEFT JOIN public.classes c ON e.class_id = c.id
        WHERE DATE(r.scanned_at AT TIME ZONE 'UTC') = CURRENT_DATE
          AND (v_role = 'super_admin' OR u.college_id = v_college_id)
          AND (v_role NOT IN ('hod', 'faculty', 'class_teacher') OR u.department_id = v_department_id)
          AND (v_role != 'class_teacher' OR c.class_teacher_id = v_user_id)
    )
    SELECT
        CASE
            WHEN COUNT(*) = 0 THEN 0
            ELSE ROUND((SUM(CASE WHEN status = 'present' THEN 1 ELSE 0 END)::NUMERIC / COUNT(*)) * 100, 1)
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

-- Retire the stale stats aggregation and its refresh machinery:
-- both remaining consumers (defaulters report + dashboard count) are live now.
-- The VIEW-or-MATVIEW handling matters because fresh installs may have the
-- phase-5 plain view instead of the materialized view.
DROP TRIGGER IF EXISTS trigger_refresh_attendance_sessions ON public.attendance_sessions;
DROP TRIGGER IF EXISTS trigger_refresh_attendance_records_admin ON public.attendance_records;
DROP FUNCTION IF EXISTS public.refresh_student_attendance_stats();
DO $$
DECLARE
    relkind CHAR;
BEGIN
    SELECT c.relkind INTO relkind
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = 'student_attendance_stats';

    IF relkind = 'm' THEN
        EXECUTE 'DROP MATERIALIZED VIEW public.student_attendance_stats';
        RAISE NOTICE 'Dropped stale materialized view student_attendance_stats.';
    ELSIF relkind = 'v' THEN
        EXECUTE 'DROP VIEW public.student_attendance_stats';
        RAISE NOTICE 'Dropped legacy plain view student_attendance_stats.';
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Could not drop student_attendance_stats (either variant): %', SQLERRM;
END $$;


-- =========================================================================
-- 5) get_faculty_audit_report — dept_admin was college-wide; now dept-scoped
--    like hod. principal stays college-wide by college. Adds search_path.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.get_faculty_audit_report()
RETURNS JSON AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_role user_role;
    v_college_id UUID;
    v_department_id UUID;
    v_result JSON;
BEGIN
    -- Perform cleanup to keep data fresh before reporting
    PERFORM public.cleanup_expired_sessions();

    SELECT role, college_id, department_id INTO v_role, v_college_id, v_department_id
    FROM public.users WHERE id = v_user_id;

    -- Only Admins, Principals, and HODs can view this
    IF v_role NOT IN ('super_admin', 'dept_admin', 'principal', 'hod') THEN
        RETURN '[]'::json;
    END IF;

    SELECT COALESCE(json_agg(row_to_json(audit)), '[]'::json) INTO v_result
    FROM (
        SELECT *
        FROM public.faculty_compliance_30d f
        WHERE (v_role = 'super_admin' OR f.college_id = v_college_id)
          AND (v_role NOT IN ('hod', 'dept_admin') OR f.department_id = v_department_id)
        ORDER BY f.lecture_date DESC, f.start_time DESC
    ) audit;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions;

GRANT SELECT ON public.faculty_compliance_30d TO authenticated;

-- =========================================================================
-- 6) get_recent_scans — role gate (super_admin/principal/hod only; students
--    and faculty were previously able to call it) + search_path hardening.
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

    -- Management/oversight view only (mirrors the dashboard's ownership)
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
    WHERE (v_role = 'super_admin' OR u.college_id = v_college_id)
      AND (v_role != 'hod' OR u.department_id = v_department_id)
    ORDER BY r.scanned_at DESC
    LIMIT 10;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions;

REVOKE ALL ON FUNCTION public.get_recent_scans() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_recent_scans() TO authenticated, service_role;


-- =========================================================================
-- Reload PostgREST schema cache
-- =========================================================================
NOTIFY pgrst, 'reload schema';
