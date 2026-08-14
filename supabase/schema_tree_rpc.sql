-- 1. Add class_teacher_id to classes if it doesn't exist
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 
        FROM information_schema.columns 
        WHERE table_name = 'classes' AND column_name = 'class_teacher_id'
    ) THEN
        ALTER TABLE public.classes ADD COLUMN class_teacher_id UUID REFERENCES public.users(id) ON DELETE SET NULL;
    END IF;
END $$;

-- 2. Create RPC to fetch the full hierarchical tree securely
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
                    'roll_number', e.roll_number
                )
            ), '[]'::json)
            FROM public.enrollments e
            JOIN public.classes cls ON e.class_id = cls.id
            JOIN public.departments d ON cls.department_id = d.id
            WHERE 
                (caller_role = 'super_admin') OR
                (caller_role = 'principal' AND d.college_id = caller_college_id) OR
                (caller_role IN ('hod', 'class_teacher', 'faculty') AND cls.department_id = caller_dept_id)
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
