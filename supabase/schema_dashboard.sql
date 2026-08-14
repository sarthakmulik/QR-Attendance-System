-- Robust Dashboard RPCs for Admin & Dept Admin

-- 1. get_dashboard_stats
CREATE OR REPLACE FUNCTION public.get_dashboard_stats()
RETURNS json AS $$
DECLARE
    v_role user_role;
    v_college_id UUID;
    
    v_total_students INTEGER;
    v_active_classes INTEGER;
    v_today_pct NUMERIC;
    v_low_count INTEGER;
    
    result json;
BEGIN
    -- Get caller identity
    SELECT role, college_id INTO v_role, v_college_id 
    FROM public.users WHERE id = auth.uid();

    -- Calculate Total Students
    SELECT COUNT(*) INTO v_total_students
    FROM public.users u
    WHERE u.role = 'student'
      AND (v_role = 'super_admin' OR u.college_id = v_college_id);

    -- Calculate Active Classes (classes in their college)
    SELECT COUNT(*) INTO v_active_classes
    FROM public.classes c
    JOIN public.departments d ON c.department_id = d.id
    WHERE (v_role = 'super_admin' OR d.college_id = v_college_id);

    -- Calculate Low Attendance Count (<75%)
    SELECT COUNT(*) INTO v_low_count
    FROM public.student_attendance_stats s
    JOIN public.users u ON s.student_id = u.id
    WHERE s.attendance_percentage < 75
      AND (v_role = 'super_admin' OR u.college_id = v_college_id);

    -- Calculate Today's Attendance Pct
    -- (Count of 'present' divided by total scans today for their college)
    WITH today_scans AS (
        SELECT r.status
        FROM public.attendance_records r
        JOIN public.users u ON r.student_id = u.id
        WHERE DATE(r.scanned_at AT TIME ZONE 'UTC') = CURRENT_DATE
          AND (v_role = 'super_admin' OR u.college_id = v_college_id)
    )
    SELECT 
        CASE 
            WHEN COUNT(*) = 0 THEN 0 
            ELSE ROUND((SUM(CASE WHEN status = 'present' THEN 1 ELSE 0 END)::NUMERIC / COUNT(*)) * 100, 1)
        END INTO v_today_pct
    FROM today_scans;

    -- Return JSON payload
    SELECT json_build_object(
        'total_students', v_total_students,
        'active_classes', v_active_classes,
        'today_attendance_pct', v_today_pct,
        'low_attendance_count', v_low_count
    ) INTO result;
    
    RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2. get_recent_scans
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
BEGIN
    SELECT role, college_id INTO v_role, v_college_id 
    FROM public.users WHERE users.id = auth.uid();

    RETURN QUERY
    SELECT 
        r.id,
        (u.first_name || ' ' || u.last_name) AS student_name,
        sub.name AS subject_name,
        r.status,
        r.scanned_at
    FROM public.attendance_records r
    JOIN public.users u ON r.student_id = u.id
    JOIN public.attendance_sessions s ON r.session_id = s.id
    JOIN public.timetable t ON s.timetable_id = t.id
    JOIN public.subjects sub ON t.subject_id = sub.id
    WHERE (v_role = 'super_admin' OR u.college_id = v_college_id)
    ORDER BY r.scanned_at DESC
    LIMIT 10;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
