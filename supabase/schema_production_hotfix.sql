-- =========================================================================
-- PRODUCTION HOTFIX (safe, additive)
-- Run this once in the Supabase SQL editor.
-- - Lets faculty start live sessions (current_token / session_secret)
-- - Accepts rotating QR tokens
-- - Assigns invited roles on signup (Principal / HOD / Class Teacher flow)
-- =========================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 1) Attendance session columns used by the live QR flow
ALTER TABLE public.attendance_sessions
  ADD COLUMN IF NOT EXISTS session_secret TEXT;
ALTER TABLE public.attendance_sessions
  ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;
ALTER TABLE public.attendance_sessions
  ADD COLUMN IF NOT EXISTS class_id UUID REFERENCES public.classes(id) ON DELETE SET NULL;
ALTER TABLE public.attendance_sessions
  ADD COLUMN IF NOT EXISTS subject_id UUID REFERENCES public.subjects(id) ON DELETE SET NULL;

UPDATE public.attendance_sessions
SET session_secret = encode(gen_random_bytes(16), 'hex')
WHERE session_secret IS NULL;

ALTER TABLE public.attendance_sessions
  ALTER COLUMN session_secret SET DEFAULT encode(gen_random_bytes(16), 'hex');

ALTER TABLE public.attendance_sessions
  ALTER COLUMN current_token SET DEFAULT 'pending';
ALTER TABLE public.attendance_sessions
  ALTER COLUMN token_expires_at SET DEFAULT (NOW() + INTERVAL '15 seconds');

-- 2) TOTP helper (must match the frontend SHA-256 of secret + window)
CREATE OR REPLACE FUNCTION public.compute_session_token(p_secret TEXT, p_window BIGINT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT substring(encode(digest(p_secret || p_window::text, 'sha256'), 'hex') FROM 1 FOR 8);
$$;

-- 3) mark_attendance: rotating token + geofence for scheduled AND ad-hoc lectures
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
    v_existing_record UUID;
    v_class_lat FLOAT;
    v_class_lng FLOAT;
    v_distance FLOAT;
    v_window BIGINT;
    v_token_ok BOOLEAN := false;
BEGIN
    v_student_id := auth.uid();
    IF v_student_id IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'Unauthorized. Please log in.');
    END IF;

    BEGIN
        PERFORM public.cleanup_expired_sessions();
    EXCEPTION WHEN undefined_function THEN
        NULL;
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

    IF v_session.class_id IS NOT NULL THEN
        SELECT c.latitude, c.longitude INTO v_class_lat, v_class_lng
        FROM public.classes c
        WHERE c.id = v_session.class_id;
    ELSIF v_session.timetable_id IS NOT NULL THEN
        SELECT c.latitude, c.longitude INTO v_class_lat, v_class_lng
        FROM public.timetable t
        JOIN public.classes c ON c.id = t.class_id
        WHERE t.id = v_session.timetable_id;
    END IF;

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

    SELECT id INTO v_existing_record
    FROM public.attendance_records
    WHERE session_id = p_session_id AND student_id = v_student_id;

    IF FOUND THEN
        RETURN json_build_object('success', true, 'message', 'Attendance already marked for this session.');
    END IF;

    INSERT INTO public.attendance_records (session_id, student_id, status, device_info)
    VALUES (p_session_id, v_student_id, 'present', p_device_info);

    RETURN json_build_object('success', true, 'message', 'Attendance marked successfully!');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 4) Invite lookup for the public signup page
CREATE OR REPLACE FUNCTION public.can_signup_with_email(p_email VARCHAR)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    invite_record RECORD;
BEGIN
    SELECT first_name, last_name, role
    INTO invite_record
    FROM public.user_invites
    WHERE lower(email) = lower(trim(p_email))
    LIMIT 1;

    IF FOUND THEN
        RETURN json_build_object(
            'allowed', true,
            'first_name', invite_record.first_name,
            'last_name', invite_record.last_name,
            'role', invite_record.role
        );
    END IF;

    RETURN json_build_object(
        'allowed', false,
        'message', 'This email has not been invited. Ask your Principal or HOD to add you first.'
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.can_signup_with_email(VARCHAR) TO anon, authenticated;

-- 5) Signup trigger: apply staged invite (role, college, class) case-insensitively
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
        INSERT INTO public.users (id, email, first_name, last_name, role, college_id, department_id)
        VALUES (
            new.id,
            new.email,
            COALESCE(invite_record.first_name, new.raw_user_meta_data->>'first_name', 'New'),
            COALESCE(invite_record.last_name, new.raw_user_meta_data->>'last_name', 'User'),
            invite_record.role,
            invite_record.college_id,
            invite_record.department_id
        )
        ON CONFLICT (id) DO UPDATE SET
            role = EXCLUDED.role,
            college_id = COALESCE(EXCLUDED.college_id, public.users.college_id),
            department_id = COALESCE(EXCLUDED.department_id, public.users.department_id),
            first_name = EXCLUDED.first_name,
            last_name = EXCLUDED.last_name;

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
        INSERT INTO public.users (id, email, first_name, last_name, role)
        VALUES (
            new.id,
            COALESCE(new.email, new.phone, 'no-email-' || new.id::text),
            COALESCE(NULLIF(new.raw_user_meta_data->>'first_name', ''), 'New'),
            COALESCE(NULLIF(new.raw_user_meta_data->>'last_name', ''), 'User'),
            'student'
        )
        ON CONFLICT (id) DO NOTHING;
    END IF;

    RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();

-- 6) Normalize emails when staging invites so signup matching is reliable
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
BEGIN
    v_email := lower(trim(p_email));
    caller_role := public.get_user_role();
    caller_college_id := public.get_user_college_id();
    caller_dept_id := public.get_user_department_id();

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
        UPDATE public.users
        SET
            role = p_role,
            college_id = p_college_id,
            department_id = p_department_id,
            first_name = COALESCE(p_first_name, first_name),
            last_name = COALESCE(p_last_name, last_name)
        WHERE id = existing_user_id
        AND (
            (college_id IS NULL AND role = 'student') OR
            (college_id = caller_college_id) OR
            caller_role = 'super_admin'
        );

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

NOTIFY pgrst, 'reload schema';
