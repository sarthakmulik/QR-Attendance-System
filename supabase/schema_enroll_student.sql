-- RPC to safely enroll or update a student's class and roll number
-- This bypasses complex client-side multi-table inserts while respecting security.

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
    SELECT c.department_id, d.college_id
    INTO target_dept_id, target_college_id
    FROM public.classes c
    JOIN public.departments d ON c.department_id = d.id
    WHERE c.id = p_class_id;

    IF target_dept_id IS NULL THEN
        RAISE EXCEPTION 'Class not found';
    END IF;

    -- 3. Verify Authorization
    -- Super Admin: Can do anything
    -- Principal: Must be in the same college
    -- HOD, Class Teacher, Faculty: Must be in the same college and department
    IF caller_role = 'super_admin' THEN
        -- allowed
    ELSIF caller_role = 'principal' AND target_college_id = caller_college_id THEN
        -- allowed
    ELSIF caller_role IN ('hod', 'class_teacher', 'faculty') 
          AND target_college_id = caller_college_id 
          AND target_dept_id = caller_dept_id THEN
        -- allowed
    ELSE
        RAISE EXCEPTION 'Unauthorized to enroll student in this class';
    END IF;

    -- 4. Upsert Enrollment
    INSERT INTO public.enrollments (student_id, class_id, roll_number)
    VALUES (p_student_id, p_class_id, p_roll_number)
    ON CONFLICT (student_id) 
    DO UPDATE SET 
        class_id = EXCLUDED.class_id,
        roll_number = EXCLUDED.roll_number,
        updated_at = NOW();

    -- Also update the student's department to match the class's department to keep it clean
    UPDATE public.users 
    SET department_id = target_dept_id 
    WHERE id = p_student_id;

    RETURN json_build_object('success', true);
END;
$$;
