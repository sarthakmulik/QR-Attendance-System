-- 1. Drop existing dynamic view
DROP VIEW IF EXISTS public.student_attendance_stats CASCADE;

-- 2. Create high-performance Materialized View
CREATE MATERIALIZED VIEW public.student_attendance_stats AS
SELECT 
    u.id AS student_id,
    u.first_name,
    u.last_name,
    u.email,
    u.college_id,
    u.department_id,
    COUNT(DISTINCT asess.id) AS total_sessions,
    COUNT(DISTINCT ar.session_id) AS attended_sessions,
    CASE 
        WHEN COUNT(DISTINCT asess.id) > 0 THEN 
            ROUND((COUNT(DISTINCT ar.session_id)::numeric / COUNT(DISTINCT asess.id)::numeric) * 100, 2)
        ELSE 0
    END AS attendance_percentage
FROM public.users u
JOIN public.enrollments e ON u.id = e.student_id
JOIN public.classes c ON e.class_id = c.id
LEFT JOIN public.attendance_sessions asess ON asess.class_id = c.id
LEFT JOIN public.attendance_records ar ON ar.session_id = asess.id AND ar.student_id = u.id
WHERE u.role = 'student'
GROUP BY u.id, u.first_name, u.last_name, u.email, u.college_id, u.department_id;

-- 3. Create unique index to allow CONCURRENTLY refresh (no read locks)
CREATE UNIQUE INDEX idx_student_attendance_stats_student ON public.student_attendance_stats (student_id);

GRANT SELECT ON public.student_attendance_stats TO authenticated;
GRANT SELECT ON public.student_attendance_stats TO anon;

-- 4. Create trigger to silently refresh cache when a lecture ends
CREATE OR REPLACE FUNCTION public.refresh_student_attendance_stats()
RETURNS TRIGGER AS $$
BEGIN
    -- Refresh concurrently so reports page never locks or freezes during refresh
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.student_attendance_stats;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trigger_refresh_attendance_sessions ON public.attendance_sessions;
CREATE TRIGGER trigger_refresh_attendance_sessions
AFTER UPDATE OF is_active ON public.attendance_sessions
FOR EACH ROW
WHEN (NEW.is_active = false AND OLD.is_active = true)
EXECUTE FUNCTION public.refresh_student_attendance_stats();

-- Also refresh if someone manually adds/removes a record from admin panel
DROP TRIGGER IF EXISTS trigger_refresh_attendance_records_admin ON public.attendance_records;
CREATE TRIGGER trigger_refresh_attendance_records_admin
AFTER DELETE ON public.attendance_records
FOR EACH STATEMENT
EXECUTE FUNCTION public.refresh_student_attendance_stats();

-- 5. Create secure RPC for Faculty to fetch only their defaulters
CREATE OR REPLACE FUNCTION public.get_faculty_defaulters(p_threshold INT)
RETURNS JSON AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_role VARCHAR;
    v_result JSON;
BEGIN
    SELECT role INTO v_role FROM public.users WHERE id = v_user_id;

    SELECT json_agg(row_to_json(stats)) INTO v_result
    FROM (
        SELECT s.*
        FROM public.student_attendance_stats s
        WHERE s.attendance_percentage < p_threshold
          AND (
              v_role IN ('super_admin', 'dept_admin', 'principal', 'hod') 
              OR 
              EXISTS (
                  -- If faculty, ensure they teach a class this student is enrolled in
                  SELECT 1 
                  FROM public.timetable t
                  JOIN public.enrollments e ON e.class_id = t.class_id
                  WHERE t.faculty_id = v_user_id AND e.student_id = s.student_id
              )
          )
        ORDER BY s.attendance_percentage ASC
        LIMIT 100
    ) stats;

    RETURN COALESCE(v_result, '[]'::json);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

NOTIFY pgrst, 'reload schema';
