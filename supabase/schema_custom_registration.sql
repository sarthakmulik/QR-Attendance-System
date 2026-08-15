-- Migration: Custom Registration Flow & Strict Class Teacher RBAC

-- 1. Upgrade user_invites with class_id and roll_number
ALTER TABLE public.user_invites ADD COLUMN IF NOT EXISTS class_id UUID REFERENCES classes(id) ON DELETE CASCADE;
ALTER TABLE public.user_invites ADD COLUMN IF NOT EXISTS roll_number VARCHAR(50);

-- 2. Update invite_or_claim_user RPC to handle staging enrollment and Class Teacher RBAC
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
BEGIN
    -- 1. Get the caller's context
    caller_role := public.get_user_role();
    caller_college_id := public.get_user_college_id();
    caller_dept_id := public.get_user_department_id();

    -- 2. Verify Caller Permissions (RBAC)
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
        -- STRICT ENFORCEMENT: If they provide a class_id, they MUST be the assigned class teacher
        IF p_class_id IS NOT NULL THEN
            SELECT class_teacher_id INTO target_class_teacher_id FROM public.classes WHERE id = p_class_id;
            IF target_class_teacher_id != auth.uid() THEN
                RAISE EXCEPTION 'Unauthorized: You are only allowed to enroll students in classes where you are explicitly assigned as the Class Teacher.';
            END IF;
        END IF;
    END IF;

    -- 3. Check if the user already exists organically in public.users
    SELECT id INTO existing_user_id FROM public.users WHERE email = p_email LIMIT 1;

    IF existing_user_id IS NOT NULL THEN
        -- The user already signed up! Update their row directly.
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
        
        -- Since they exist, we must also instantly enroll them in the class
        IF p_class_id IS NOT NULL AND p_roll_number IS NOT NULL THEN
            INSERT INTO public.enrollments (student_id, class_id, roll_number)
            VALUES (existing_user_id, p_class_id, p_roll_number)
            ON CONFLICT (student_id, class_id) DO UPDATE SET roll_number = EXCLUDED.roll_number;
        END IF;

        -- Delete any stuck invites
        DELETE FROM public.user_invites WHERE email = p_email;
        
        RETURN json_build_object('status', 'claimed', 'user_id', existing_user_id);
    ELSE
        -- The user hasn't signed up yet. STAGE the student! No Supabase Auth invite is sent.
        INSERT INTO public.user_invites (email, role, college_id, department_id, created_by, first_name, last_name, class_id, roll_number)
        VALUES (p_email, p_role, p_college_id, p_department_id, auth.uid(), p_first_name, p_last_name, p_class_id, p_roll_number)
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
            
        -- We return 'staged' instead of 'invited' to signify the custom flow
        RETURN json_build_object('status', 'staged', 'message', 'Student data staged. Awaiting signup.');
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 3. Upgrade handle_new_user trigger to handle the auto-enrollment!
CREATE OR REPLACE FUNCTION public.handle_new_user() 
RETURNS TRIGGER AS $$
DECLARE
  invite_record RECORD;
BEGIN
  -- Check if the email exists in the user_invites table
  SELECT * INTO invite_record FROM public.user_invites WHERE email = new.email;
  
  IF FOUND THEN
    -- If an invite exists, assign the predefined role and affiliations
    INSERT INTO public.users (id, email, first_name, last_name, role, college_id, department_id)
    VALUES (
      new.id, 
      new.email, 
      COALESCE(invite_record.first_name, new.raw_user_meta_data->>'first_name', 'New'),
      COALESCE(invite_record.last_name, new.raw_user_meta_data->>'last_name', 'User'),
      invite_record.role,
      invite_record.college_id,
      invite_record.department_id
    );

    -- AUTO-ENROLL if class data was staged
    IF invite_record.class_id IS NOT NULL AND invite_record.roll_number IS NOT NULL THEN
        INSERT INTO public.enrollments (student_id, class_id, roll_number)
        VALUES (new.id, invite_record.class_id, invite_record.roll_number)
        ON CONFLICT (student_id, class_id) DO NOTHING;
    END IF;

    -- Delete the invite so it's not lingering
    DELETE FROM public.user_invites WHERE email = new.email;
  ELSE
    -- If no invite, fallback to the default (student)
    INSERT INTO public.users (id, email, first_name, last_name, role)
    VALUES (
      new.id, 
      new.email, 
      COALESCE(new.raw_user_meta_data->>'first_name', 'New'),
      COALESCE(new.raw_user_meta_data->>'last_name', 'User'),
      'student'
    );
  END IF;

  RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 4. Secure the standalone enroll_student RPC
CREATE OR REPLACE FUNCTION public.enroll_student(
    p_student_id uuid,
    p_class_id uuid,
    p_roll_number text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    caller_role text;
    caller_college_id uuid;
    caller_dept_id uuid;
    target_dept_id uuid;
    target_college_id uuid;
    target_class_teacher_id uuid;
BEGIN
    -- 1. Get caller's details
    SELECT role, college_id, department_id 
    INTO caller_role, caller_college_id, caller_dept_id
    FROM public.users
    WHERE id = auth.uid();

    -- Ensure caller exists
    IF caller_role IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    -- 2. Get target class details (to verify permissions)
    SELECT c.department_id, d.college_id, c.class_teacher_id
    INTO target_dept_id, target_college_id, target_class_teacher_id
    FROM public.classes c
    JOIN public.departments d ON c.department_id = d.id
    WHERE c.id = p_class_id;

    IF target_dept_id IS NULL THEN
        RAISE EXCEPTION 'Class not found';
    END IF;

    -- 3. Verify Authorization
    IF caller_role = 'super_admin' THEN
        -- allowed
    ELSIF caller_role = 'principal' AND target_college_id = caller_college_id THEN
        -- allowed
    ELSIF caller_role = 'hod' AND target_college_id = caller_college_id AND target_dept_id = caller_dept_id THEN
        -- allowed
    ELSIF caller_role = 'class_teacher' THEN
        IF target_college_id != caller_college_id OR target_dept_id != caller_dept_id THEN
             RAISE EXCEPTION 'Unauthorized: Cannot enroll in classes outside your department';
        END IF;
        IF target_class_teacher_id != auth.uid() THEN
             RAISE EXCEPTION 'Unauthorized: You are only allowed to enroll students in classes where you are explicitly assigned as the Class Teacher.';
        END IF;
    ELSE
        RAISE EXCEPTION 'Unauthorized to enroll student in this class';
    END IF;

    -- 4. Upsert Enrollment
    INSERT INTO public.enrollments (student_id, class_id, roll_number)
    VALUES (p_student_id, p_class_id, p_roll_number)
    ON CONFLICT (student_id, class_id) 
    DO UPDATE SET 
        roll_number = EXCLUDED.roll_number,
        updated_at = NOW();

    -- Also update the student's department to match the class's department to keep it clean
    UPDATE public.users 
    SET department_id = target_dept_id 
    WHERE id = p_student_id;

    RETURN json_build_object('status', 'success', 'message', 'Student enrolled successfully');
END;
$$;
