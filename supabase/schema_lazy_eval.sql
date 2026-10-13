-- =========================================================================
-- SCHEMA: Lazy Evaluation for Auto-Closing Expired Sessions
-- File: supabase/schema_lazy_eval.sql
-- =========================================================================

-- 1. Create cleanup function for expired sessions
CREATE OR REPLACE FUNCTION public.cleanup_expired_sessions()
RETURNS void AS $$
BEGIN
    UPDATE public.attendance_sessions
    SET is_active = false
    WHERE is_active = true 
      AND expires_at IS NOT NULL 
      AND expires_at <= NOW();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2. Embed cleanup into dashboard stats RPC (runs lazily on every dashboard load)
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

    -- Calculate Defaulters (Below 75%)
    SELECT COUNT(DISTINCT s.student_id) INTO v_low_count
    FROM public.student_attendance_stats s
    JOIN public.users u ON s.student_id = u.id
    LEFT JOIN public.enrollments e ON u.id = e.student_id
    LEFT JOIN public.classes c ON e.class_id = c.id
    WHERE s.attendance_percentage < 75
      AND (v_role = 'super_admin' OR u.college_id = v_college_id)
      AND (v_role NOT IN ('hod', 'faculty', 'class_teacher') OR u.department_id = v_department_id)
      AND (v_role != 'class_teacher' OR c.class_teacher_id = v_user_id);

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
$$ LANGUAGE plpgsql SECURITY DEFINER;

NOTIFY pgrst, 'reload schema';
