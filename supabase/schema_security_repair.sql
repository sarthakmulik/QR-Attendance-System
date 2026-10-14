-- =========================================================================
-- SECURITY & INTEGRITY REPAIR (Phase 2, additive/safe)
-- Run this once in the Supabase SQL editor, AFTER schema_production_hotfix.sql.
--
-- 1) Locks down attendance_sessions (closes the session_secret leak)
-- 2) Removes anon/authenticated table access to student_attendance_stats
--    (replaced by authorized RPCs)
-- 3) Hardens mark_attendance (role + enrollment checks, race-safe insert)
-- 4) Restricts who can CREATE attendance sessions (RLS role check)
-- 5) Fixes invite_or_claim_user (college wipe on super-admin edit,
--    silent no-op, marks role_assigned)
-- 6) Fixes create_college_with_admin staging the dead 'dept_admin' role
-- 7) Adds role_assigned tracking for the "pending role" signup UX
-- 8) Fixes get_recent_scans to include ad-hoc sessions (LEFT JOIN)
--
-- This script is fully re-runnable: every statement is guarded
-- (DROP ... IF EXISTS / CREATE OR REPLACE / ALTER ... IF NOT EXISTS),
-- so it can be pasted again after a partial failure.
-- =========================================================================

-- ---------------------------------------------------------------------------
-- 1) ATTENDANCE_SESSIONS: stop leaking session_secret / current_token
--    The rotating-QR design requires the TOTP secret to be readable ONLY by
--    the owning faculty (and management for oversight).
-- ---------------------------------------------------------------------------

-- Was: SELECT USING (true) -> any anon/authenticated client could read every
-- live session's session_secret and mint valid QR tokens.
--
-- The old "Faculty can manage their own sessions" FOR ALL policy also let any
-- faculty INSERT a session for ANY division (started from the ad-hoc form or
-- forged with a direct API call). Policies are split per command so the
-- INSERT can additionally require entitlement to that division.

DROP POLICY IF EXISTS "Anyone can view active sessions (for students to join)" ON public.attendance_sessions;
DROP POLICY IF EXISTS "Faculty can manage their own sessions" ON public.attendance_sessions;
DROP POLICY IF EXISTS "Faculty can view their own sessions" ON public.attendance_sessions;
DROP POLICY IF EXISTS "Faculty can create sessions for their divisions" ON public.attendance_sessions;
DROP POLICY IF EXISTS "Faculty can update their own sessions" ON public.attendance_sessions;
DROP POLICY IF EXISTS "Faculty can delete their own sessions" ON public.attendance_sessions;
DROP POLICY IF EXISTS "Super Admins can view all attendance sessions" ON public.attendance_sessions;
DROP POLICY IF EXISTS "Principals can view sessions in their college" ON public.attendance_sessions;

-- SELECT: owner (plus management oversight further down).
CREATE POLICY "Faculty can view their own sessions"
    ON public.attendance_sessions
    FOR SELECT
    USING (
        auth.uid() = faculty_id
        AND public.get_user_role() IN ('super_admin', 'principal', 'hod', 'class_teacher', 'faculty')
    );

-- INSERT: the creator must be entitled to THAT division:
--   * scheduled lecture: they own the timetable slot, OR
--   * they teach the target class or subject somewhere in the timetable
--     (covers ad-hoc lectures and substitution), OR
--   * they are the Class Teacher of the target class, OR
--   * management override (super_admin / principal / hod).
-- NULL class_id/subject_id/timetable_id never satisfies a branch, so a
-- session not linked to any division cannot be created at all.
CREATE POLICY "Faculty can create sessions for their divisions"
    ON public.attendance_sessions
    FOR INSERT
    WITH CHECK (
        auth.uid() = faculty_id
        AND public.get_user_role() IN ('super_admin', 'principal', 'hod', 'class_teacher', 'faculty')
        AND (
            public.get_user_role() IN ('super_admin', 'principal', 'hod')
            OR (timetable_id IS NOT NULL AND EXISTS (
                SELECT 1 FROM public.timetable t
                WHERE t.id = attendance_sessions.timetable_id
                  AND t.faculty_id = auth.uid()
            ))
            OR EXISTS (
                SELECT 1 FROM public.timetable t
                WHERE t.faculty_id = auth.uid()
                  AND (   t.class_id   = attendance_sessions.class_id
                       OR t.subject_id = attendance_sessions.subject_id)
            )
            OR EXISTS (
                SELECT 1 FROM public.classes c
                WHERE c.id = attendance_sessions.class_id
                  AND c.class_teacher_id = auth.uid()
            )
        )
    );

-- UPDATE: owner keeps full control of their own session. Deliberately no
-- division constraint here: a faculty replaced mid-lecture must still be
-- able to end their session (expiry auto-ends it anyway).
CREATE POLICY "Faculty can update their own sessions"
    ON public.attendance_sessions
    FOR UPDATE
    USING (
        auth.uid() = faculty_id
        AND public.get_user_role() IN ('super_admin', 'principal', 'hod', 'class_teacher', 'faculty')
    )
    WITH CHECK (
        auth.uid() = faculty_id
        AND public.get_user_role() IN ('super_admin', 'principal', 'hod', 'class_teacher', 'faculty')
    );

-- DELETE: owner only.
CREATE POLICY "Faculty can delete their own sessions"
    ON public.attendance_sessions
    FOR DELETE
    USING (
        auth.uid() = faculty_id
        AND public.get_user_role() IN ('super_admin', 'principal', 'hod', 'class_teacher', 'faculty')
    );

CREATE POLICY "Super Admins can view all attendance sessions"
    ON public.attendance_sessions
    FOR SELECT
    USING ( public.get_user_role() = 'super_admin' );

CREATE POLICY "Principals can view sessions in their college"
    ON public.attendance_sessions
    FOR SELECT
    USING (
        public.get_user_role() = 'principal'
        AND EXISTS (
            SELECT 1
            FROM public.classes c
            JOIN public.departments d ON c.department_id = d.id
            WHERE d.college_id = public.get_user_college_id()
              AND (
                    c.id = attendance_sessions.class_id
                    OR (
                        attendance_sessions.timetable_id IS NOT NULL
                        AND c.id = (
                            SELECT class_id FROM public.timetable
                            WHERE id = attendance_sessions.timetable_id
                        )
                    )
              )
        )
    );

-- ---------------------------------------------------------------------------
-- 2) STUDENT_ATTENDANCE_STATS (materialized view): revoke table access.
--    Materialized views bypass RLS, so the previous grants exposed every
--    student's name/email/attendance to anon and to any logged-in user.
--    The frontend now uses the authorized RPCs created below.
-- ---------------------------------------------------------------------------

REVOKE ALL ON public.student_attendance_stats FROM anon;
REVOKE ALL ON public.student_attendance_stats FROM authenticated;

-- The phase-5 plain view is also owner-executed (underlying RLS is bypassed
-- for views), so lock it down too. The frontend uses the RPC below instead.
REVOKE ALL ON public.subject_attendance_stats FROM anon;
REVOKE ALL ON public.subject_attendance_stats FROM authenticated;

-- Faculty compliance view is admin-only via get_faculty_audit_report() RPC;
-- direct table-style reads would leak faculty schedules to any logged-in user.
REVOKE ALL ON public.faculty_compliance_30d FROM anon;
REVOKE ALL ON public.faculty_compliance_30d FROM authenticated;

-- 2a) Authorized replacement RPC: overall stats (self or in-scope management)
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

    SELECT
        COUNT(DISTINCT s.id),
        COUNT(DISTINCT r.session_id)
    INTO v_total, v_attended
    FROM public.users u
    JOIN public.enrollments e ON u.id = e.student_id
    JOIN public.classes c ON e.class_id = c.id
    LEFT JOIN public.attendance_sessions s ON s.class_id = c.id
    LEFT JOIN public.attendance_records r ON r.session_id = s.id AND r.student_id = u.id
    WHERE u.id = p_student_id;

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

-- 2b) Authorized replacement RPC: subject-wise stats (same authorization)
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
        JOIN public.classes c ON e.class_id = c.id
        JOIN public.timetable t ON t.class_id = c.id
        JOIN public.subjects sub ON t.subject_id = sub.id
        LEFT JOIN public.attendance_sessions s ON s.timetable_id = t.id
        LEFT JOIN public.attendance_records r ON r.session_id = s.id AND r.student_id = e.student_id
        WHERE e.student_id = p_student_id
        GROUP BY sub.id, sub.name, sub.code
    ) stats;

    RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_student_attendance_stats(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_subject_attendance_stats(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3) mark_attendance: role check + enrollment check + race-safe insert
-- ---------------------------------------------------------------------------

-- Defensive: the ON CONFLICT insert below requires
-- UNIQUE(session_id, student_id). schema_phase4.sql created the table with
-- that constraint; re-assert it in case the live DB diverged. The whole block
-- is exception-guarded so a pre-existing duplicate row can never abort this
-- script (a NOTICE is raised instead).
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'public'
          AND tablename = 'attendance_records'
          AND indexname = 'uq_attendance_records_session_student'
    ) THEN
        CREATE UNIQUE INDEX uq_attendance_records_session_student
            ON public.attendance_records (session_id, student_id);
        RAISE NOTICE 'Created missing unique index uq_attendance_records_session_student';
    END IF;
EXCEPTION
    WHEN duplicate_table THEN NULL; -- created concurrently by another run
    WHEN others THEN
        RAISE NOTICE 'Skipped unique index on attendance_records: %', SQLERRM;
END $$;

-- Drop EVERY existing mark_attendance overload before recreating it.
-- schema_phase4.sql created a 3-argument version WITHOUT the enrollment and
-- geofence checks. CREATE OR REPLACE cannot remove it (different argument
-- list), so it would survive as a bypass: any client calling with only
-- p_session_id/p_token/p_device_info hits the old, ungated function.
DO $$
DECLARE v_sig TEXT;
BEGIN
    FOR v_sig IN
        SELECT p.oid::regprocedure::text
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'mark_attendance'
    LOOP
        EXECUTE format('DROP FUNCTION %s', v_sig);
    END LOOP;
END $$;

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
    v_token_ok BOOLEAN := false;
    v_inserted BIGINT := 0;
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

    IF v_session.session_secret IS NOT NULL AND length(v_session.session_secret) > 0 THEN
        IF p_token = public.compute_session_token(v_session.session_secret, v_window)
           OR p_token = public.compute_session_token(v_session.session_secret, v_window - 1)
           OR p_token = public.compute_session_token(v_session.session_secret, v_window + 1) THEN
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

    -- Race-safe insert: UNIQUE(session_id, student_id) + ON CONFLICT means
    -- concurrent duplicate scans can never create duplicate rows, and the
    -- student gets a friendly message instead of a raw 23505 error.
    INSERT INTO public.attendance_records (session_id, student_id, status, device_info)
    VALUES (p_session_id, v_student_id, 'present', p_device_info)
    ON CONFLICT (session_id, student_id) DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    IF v_inserted = 0 THEN
        RETURN json_build_object('success', true, 'message', 'Attendance already marked for this session.');
    END IF;

    RETURN json_build_object('success', true, 'message', 'Attendance marked successfully!');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ---------------------------------------------------------------------------
-- 5) invite_or_claim_user: preserve college/department on super-admin edits,
--    fail loudly when the guarded UPDATE matches nothing, mark role_assigned.
-- ---------------------------------------------------------------------------

-- The live DB runs a later variant of this function whose parameters carry
-- extra defaults. CREATE OR REPLACE cannot remove existing parameter defaults
-- (ERROR 42P13: "cannot remove parameter defaults from existing function"),
-- so drop first, then create. The argument types are identical, so callers
-- (PostgREST RPC by name) are unaffected.
DROP FUNCTION IF EXISTS public.invite_or_claim_user(
    character varying, user_role, uuid, uuid,
    character varying, character varying, uuid, character varying
);
-- Also clean up the legacy 6-argument overload left behind by older patches.
DROP FUNCTION IF EXISTS public.invite_or_claim_user(
    character varying, user_role, uuid, uuid,
    character varying, character varying
);

CREATE OR REPLACE FUNCTION public.invite_or_claim_user(
    p_email VARCHAR(255),
    p_role user_role,
    p_college_id UUID,
    p_department_id UUID DEFAULT NULL,
    p_first_name VARCHAR(100) DEFAULT NULL,
    p_last_name VARCHAR(100) DEFAULT NULL,
    p_class_id UUID DEFAULT NULL,
    p_roll_number VARCHAR(50) DEFAULT NULL
) RETURNS json AS $$
DECLARE
    existing_user_id UUID;
    caller_role user_role;
    caller_college_id UUID;
    caller_dept_id UUID;
    target_class_teacher_id UUID;
    v_email VARCHAR(255);
    v_updated BIGINT := 0;
BEGIN
    v_email := lower(trim(p_email));
    caller_role := public.get_user_role();
    caller_college_id := public.get_user_college_id();
    caller_dept_id := public.get_user_department_id();

    IF caller_role IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    IF caller_role = 'student' OR caller_role = 'faculty' THEN
        RAISE EXCEPTION 'Unauthorized: You do not have permission to invite users.';
    END IF;

    IF caller_role = 'principal' THEN
        IF p_college_id IS DISTINCT FROM caller_college_id THEN
            RAISE EXCEPTION 'Unauthorized: Principals can only invite users to their own college.';
        END IF;
        IF p_role IN ('super_admin', 'principal') THEN
            RAISE EXCEPTION 'Unauthorized: Principals cannot assign super_admin or principal roles.';
        END IF;
    END IF;

    IF caller_role = 'hod' THEN
        IF p_college_id IS DISTINCT FROM caller_college_id OR p_department_id IS DISTINCT FROM caller_dept_id THEN
            RAISE EXCEPTION 'Unauthorized: HODs can only invite users to their own department.';
        END IF;
        IF p_role IN ('super_admin', 'principal', 'hod') THEN
            RAISE EXCEPTION 'Unauthorized: HODs cannot assign management roles above class_teacher.';
        END IF;
    END IF;

    IF caller_role = 'class_teacher' THEN
        IF p_college_id IS DISTINCT FROM caller_college_id OR p_department_id IS DISTINCT FROM caller_dept_id THEN
            RAISE EXCEPTION 'Unauthorized: Class Teachers can only invite users to their own department.';
        END IF;
        IF p_role != 'student' THEN
            RAISE EXCEPTION 'Unauthorized: Class Teachers can only invite students.';
        END IF;
        IF p_class_id IS NOT NULL THEN
            SELECT class_teacher_id INTO target_class_teacher_id FROM public.classes WHERE id = p_class_id;
            IF target_class_teacher_id IS DISTINCT FROM auth.uid() THEN
                RAISE EXCEPTION 'Unauthorized: You are only allowed to enroll students in classes where you are explicitly assigned as the Class Teacher.';
            END IF;
        END IF;
    END IF;

    SELECT id INTO existing_user_id FROM public.users WHERE lower(email) = v_email LIMIT 1;

    IF existing_user_id IS NOT NULL THEN
        -- COALESCE keeps college/department intact when the caller sends NULL
        -- (previously a super-admin role edit wiped the user's college).
        UPDATE public.users
        SET
            role = p_role,
            college_id = COALESCE(p_college_id, college_id),
            department_id = COALESCE(p_department_id, department_id),
            first_name = COALESCE(p_first_name, first_name),
            last_name = COALESCE(p_last_name, last_name),
            role_assigned = TRUE
        WHERE id = existing_user_id
        AND (
            (college_id IS NULL AND role = 'student') OR
            (college_id = caller_college_id) OR
            caller_role = 'super_admin'
        );

        GET DIAGNOSTICS v_updated = ROW_COUNT;
        IF v_updated = 0 THEN
            RAISE EXCEPTION 'Could not update this user. You may not have permission to modify users outside your scope.';
        END IF;

        IF p_class_id IS NOT NULL THEN
            IF p_role = 'student' AND p_roll_number IS NOT NULL THEN
                INSERT INTO public.enrollments (student_id, class_id, roll_number)
                VALUES (existing_user_id, p_class_id, p_roll_number)
                ON CONFLICT (student_id, class_id) DO UPDATE SET roll_number = EXCLUDED.roll_number;
            ELSIF p_role = 'class_teacher' THEN
                UPDATE public.classes SET class_teacher_id = existing_user_id WHERE id = p_class_id;
            END IF;
        END IF;

        DELETE FROM public.user_invites WHERE lower(email) = v_email;

        RETURN json_build_object('status', 'claimed', 'user_id', existing_user_id);
    ELSE
        INSERT INTO public.user_invites (email, role, college_id, department_id, created_by, first_name, last_name, class_id, roll_number)
        VALUES (v_email, p_role, p_college_id, p_department_id, auth.uid(), p_first_name, p_last_name, p_class_id, p_roll_number)
        ON CONFLICT (email) DO UPDATE
        SET
            role = EXCLUDED.role,
            college_id = EXCLUDED.college_id,
            department_id = EXCLUDED.department_id,
            created_by = EXCLUDED.created_by,
            first_name = EXCLUDED.first_name,
            last_name = EXCLUDED.last_name,
            class_id = EXCLUDED.class_id,
            roll_number = EXCLUDED.roll_number;

        RETURN json_build_object('status', 'staged', 'message', 'User data staged. Awaiting signup.');
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ---------------------------------------------------------------------------
-- 6) create_college_with_admin: stage 'principal' (the old 'dept_admin' role
--    no longer has any RLS policies after the RBAC upgrade -> dead accounts).
-- ---------------------------------------------------------------------------

-- Same 42P13 precaution as invite_or_claim_user: drop first in case the live
-- variant has parameter defaults this definition doesn't.
DROP FUNCTION IF EXISTS public.create_college_with_admin(
    character varying, text, character varying
);

CREATE OR REPLACE FUNCTION public.create_college_with_admin(
    p_name VARCHAR(255),
    p_address TEXT,
    p_contact_email VARCHAR(255)
) RETURNS json AS $$
DECLARE
    new_college_id UUID;
    result json;
BEGIN
    IF public.get_user_role() != 'super_admin' THEN
        RAISE EXCEPTION 'Only super admins can create colleges';
    END IF;

    INSERT INTO public.colleges (name, address, contact_email)
    VALUES (p_name, p_address, p_contact_email)
    RETURNING id INTO new_college_id;

    IF p_contact_email IS NOT NULL AND p_contact_email != '' THEN
        INSERT INTO public.user_invites (email, role, college_id, created_by)
        VALUES (lower(trim(p_contact_email)), 'principal'::user_role, new_college_id, auth.uid())
        ON CONFLICT (email) DO UPDATE
        SET role = 'principal'::user_role, college_id = new_college_id;
    END IF;

    SELECT row_to_json(c) INTO result FROM public.colleges c WHERE id = new_college_id;
    RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ---------------------------------------------------------------------------
-- 7) role_assigned tracking:
--    Anyone can still SIGN UP, but only users whose role was assigned by an
--    admin (via invite_or_claim_user) get the dashboard UI. Everyone else
--    sees a "contact your administrator" screen.
-- ---------------------------------------------------------------------------

ALTER TABLE public.users ADD COLUMN IF NOT EXISTS role_assigned BOOLEAN NOT NULL DEFAULT FALSE;

-- All pre-existing accounts are established users -> treat as assigned.
UPDATE public.users SET role_assigned = TRUE WHERE role_assigned = FALSE;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
DECLARE
    invite_record RECORD;
BEGIN
    SELECT * INTO invite_record
    FROM public.user_invites
    WHERE lower(email) = lower(new.email)
    LIMIT 1;

    IF FOUND THEN
        INSERT INTO public.users (id, email, first_name, last_name, role, college_id, department_id, role_assigned)
        VALUES (
            new.id,
            new.email,
            COALESCE(invite_record.first_name, NULLIF(new.raw_user_meta_data->>'first_name', ''), 'New'),
            COALESCE(invite_record.last_name, NULLIF(new.raw_user_meta_data->>'last_name', ''), 'User'),
            invite_record.role,
            invite_record.college_id,
            invite_record.department_id,
            TRUE
        )
        ON CONFLICT (id) DO UPDATE SET
            role = EXCLUDED.role,
            college_id = COALESCE(EXCLUDED.college_id, public.users.college_id),
            department_id = COALESCE(EXCLUDED.department_id, public.users.department_id),
            first_name = EXCLUDED.first_name,
            last_name = EXCLUDED.last_name,
            role_assigned = TRUE;

        IF invite_record.class_id IS NOT NULL THEN
            IF invite_record.role = 'student' AND invite_record.roll_number IS NOT NULL THEN
                INSERT INTO public.enrollments (student_id, class_id, roll_number)
                VALUES (new.id, invite_record.class_id, invite_record.roll_number)
                ON CONFLICT (student_id, class_id) DO NOTHING;
            ELSIF invite_record.role = 'class_teacher' THEN
                UPDATE public.classes SET class_teacher_id = new.id WHERE id = invite_record.class_id;
            END IF;
        END IF;

        DELETE FROM public.user_invites WHERE lower(email) = lower(new.email);
    ELSE
        -- Organic signup: account is created, but role_assigned stays FALSE
        -- until an admin claims them via invite_or_claim_user.
        INSERT INTO public.users (id, email, first_name, last_name, role, role_assigned)
        VALUES (
            new.id,
            COALESCE(new.email, new.phone, 'no-email-' || new.id::text),
            COALESCE(NULLIF(new.raw_user_meta_data->>'first_name', ''), 'New'),
            COALESCE(NULLIF(new.raw_user_meta_data->>'last_name', ''), 'User'),
            'student',
            FALSE
        )
        ON CONFLICT (id) DO NOTHING;
    END IF;

    RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Make sure the trigger wiring exists (same pattern as
-- schema_production_hotfix.sql). Harmless no-op if it's already in place.
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();

-- ---------------------------------------------------------------------------
-- 8) get_recent_scans: include ad-hoc sessions (timetable_id IS NULL)
-- ---------------------------------------------------------------------------

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
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ---------------------------------------------------------------------------
-- Reload PostgREST schema cache
-- ---------------------------------------------------------------------------

NOTIFY pgrst, 'reload schema';
