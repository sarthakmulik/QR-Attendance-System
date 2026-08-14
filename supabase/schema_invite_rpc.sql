-- Advanced Invite or Claim User RPC
-- This safely allows Principals/HODs/Class Teachers to invite a new user OR claim an existing unassigned user.

CREATE OR REPLACE FUNCTION public.invite_or_claim_user(
    p_email VARCHAR(255),
    p_role user_role,
    p_college_id UUID,
    p_department_id UUID DEFAULT NULL
) RETURNS json AS $$
DECLARE
    existing_user_id UUID;
    caller_role user_role;
    caller_college_id UUID;
    caller_dept_id UUID;
BEGIN
    -- 1. Get the caller's context
    caller_role := public.get_user_role();
    caller_college_id := public.get_user_college_id();
    caller_dept_id := public.get_user_department_id();

    -- 2. Verify Caller Permissions
    IF caller_role = 'student' OR caller_role = 'faculty' THEN
        RAISE EXCEPTION 'Unauthorized: You do not have permission to invite users.';
    END IF;

    IF caller_role = 'principal' THEN
        IF p_college_id != caller_college_id THEN
            RAISE EXCEPTION 'Unauthorized: Principals can only invite users to their own college.';
        END IF;
        IF p_role IN ('super_admin', 'principal') THEN
            RAISE EXCEPTION 'Unauthorized: Principals cannot assign super_admin or principal roles.';
        END IF;
    END IF;

    IF caller_role = 'hod' THEN
        IF p_college_id != caller_college_id OR p_department_id != caller_dept_id THEN
            RAISE EXCEPTION 'Unauthorized: HODs can only invite users to their own department.';
        END IF;
        IF p_role IN ('super_admin', 'principal', 'hod') THEN
            RAISE EXCEPTION 'Unauthorized: HODs cannot assign management roles above class_teacher.';
        END IF;
    END IF;

    IF caller_role = 'class_teacher' THEN
        IF p_college_id != caller_college_id OR p_department_id != caller_dept_id THEN
            RAISE EXCEPTION 'Unauthorized: Class Teachers can only invite users to their own department.';
        END IF;
        IF p_role != 'student' THEN
            RAISE EXCEPTION 'Unauthorized: Class Teachers can only invite students.';
        END IF;
    END IF;

    -- 3. Check if the user already exists organically in public.users
    SELECT id INTO existing_user_id FROM public.users WHERE email = p_email LIMIT 1;

    IF existing_user_id IS NOT NULL THEN
        -- The user already signed up! Update their row directly.
        -- We only allow claiming if they are currently an unassigned student OR if they already belong to this caller's college.
        UPDATE public.users 
        SET 
            role = p_role,
            college_id = p_college_id,
            department_id = p_department_id
        WHERE id = existing_user_id 
        AND (
            (college_id IS NULL AND role = 'student') OR 
            (college_id = caller_college_id) OR
            caller_role = 'super_admin'
        );
        
        -- Also delete any stuck invites just in case
        DELETE FROM public.user_invites WHERE email = p_email;
        
        RETURN json_build_object('status', 'claimed', 'user_id', existing_user_id);
    ELSE
        -- The user hasn't signed up yet. Stage the invite!
        -- We use ON CONFLICT DO UPDATE so it overwrites any stuck/old invites without throwing a 409 Conflict!
        INSERT INTO public.user_invites (email, role, college_id, department_id, created_by)
        VALUES (p_email, p_role, p_college_id, p_department_id, auth.uid())
        ON CONFLICT (email) DO UPDATE 
        SET 
            role = EXCLUDED.role,
            college_id = EXCLUDED.college_id,
            department_id = EXCLUDED.department_id,
            created_by = EXCLUDED.created_by;

        RETURN json_build_object('status', 'invited', 'email', p_email);
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
