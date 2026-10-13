-- =========================================================================
-- SCHEMA: Faculty Compliance Audit (30-Day Lookback)
-- File: supabase/schema_faculty_audit.sql
-- =========================================================================

-- 1. Create a lazy cleanup function that can be called to auto-close expired sessions
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

-- 2. Faculty Compliance View
CREATE OR REPLACE VIEW public.faculty_compliance_30d AS
SELECT 
    t.id AS timetable_id,
    t.faculty_id,
    u.first_name,
    u.last_name,
    u.department_id,
    d.college_id,
    t.class_id,
    c.name AS class_name,
    c.semester,
    t.subject_id,
    s.name AS subject_name,
    s.code AS subject_code,
    t.day_of_week,
    t.start_time,
    t.end_time,
    series.date AS lecture_date,
    CASE 
        WHEN a.id IS NOT NULL THEN 'Present'
        ELSE 'Absent'
    END AS status,
    a.id AS session_id,
    a.created_at AS session_started_at
FROM 
    public.timetable t
JOIN 
    public.users u ON t.faculty_id = u.id
JOIN 
    public.departments d ON u.department_id = d.id
JOIN 
    public.classes c ON t.class_id = c.id
JOIN 
    public.subjects s ON t.subject_id = s.id
CROSS JOIN 
    -- Generate the last 30 days
    (SELECT (CURRENT_DATE - i) AS date FROM generate_series(0, 30) i) series
LEFT JOIN 
    public.attendance_sessions a 
    ON a.timetable_id = t.id 
    AND DATE(a.created_at AT TIME ZONE 'UTC') = series.date
WHERE 
    -- Only match dates where the day_of_week matches the timetable's day_of_week
    EXTRACT(ISODOW FROM series.date) = t.day_of_week
    -- And the lecture time must have already passed to be considered 'Absent'
    AND (series.date < CURRENT_DATE OR (series.date = CURRENT_DATE AND t.start_time <= CURRENT_TIME::time));

-- 3. Secure RPC to fetch compliance report with RBAC
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
          AND (v_role != 'hod' OR f.department_id = v_department_id)
        ORDER BY f.lecture_date DESC, f.start_time DESC
    ) audit;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant permissions
GRANT SELECT ON public.faculty_compliance_30d TO authenticated;

NOTIFY pgrst, 'reload schema';
