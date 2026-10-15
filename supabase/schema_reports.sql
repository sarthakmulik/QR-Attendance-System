-- =========================================================================
-- REPORTING RPCs — Department-wise / Subject-wise / Monthly summaries
-- Run in the Supabase SQL editor AFTER schema_security_repair.sql.
--
-- The Reports page shipped three "Quick Report" buttons (Department-wise
-- Summary, Subject-wise Summary, Monthly Attendance Log) that were dead
-- placeholders, and there was no way to summarise lecture history by
-- department, subject or month.
--
-- attendance_records / attendance_sessions are RLS-locked on purpose (see
-- schema_security_repair.sql), so these summaries are SECURITY DEFINER RPCs
-- with an explicit per-student scope check rather than client-side queries.
--
-- WHY RETURNS JSON (not RETURNS TABLE):
--   The first version declared RETURNS TABLE, which made plpgsql validate
--   the RETURN QUERY shape against the declared column types and fail with
--   42804 "structure of query does not match function result type".
--   Building the payload with json_agg(row_to_json(...)) has no such check,
--   naturally returns [] for "no data", and produces exactly the object keys
--   the frontend already reads — so the frontend needed no change. Same
--   shape get_faculty_defaulters has always used. Each function is DROPped
--   first because CREATE OR REPLACE cannot change a return type.
--
-- SCOPE RULE (shared helper is_student_in_scope):
--   super_admin            -> everything
--   principal              -> own college
--   hod                    -> own department
--   class_teacher/faculty  -> students enrolled in classes they teach
--   anyone else (incl. anon) -> empty result
--
-- A session's class/subject is resolved with COALESCE(session.<x>,
-- timetable.<x>) because scheduled sessions carry timetable_id and ad-hoc
-- sessions carry class_id/subject_id directly.
-- =========================================================================

-- ---------------------------------------------------------------------------
-- 0) Drop any previously installed versions. Required, not cosmetic:
--    CREATE OR REPLACE cannot change a return type (42804), and the live DB
--    may hold RETURN TABLE variants or differently-defaulted overloads.
-- ---------------------------------------------------------------------------
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS sig
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname IN ('is_student_in_scope',
                            'get_department_attendance_summary',
                            'get_subject_attendance_summary',
                            'get_monthly_attendance_log',
                            'get_faculty_defaulters')
    LOOP
        EXECUTE format('DROP FUNCTION IF EXISTS %s', r.sig);
    END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 1) Scope helper: is this student visible to the caller?
--    NULL-safe: if the caller has no college_id/department_id, the equality
--    yields NULL rather than matching every NULL row.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.is_student_in_scope(p_student_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.users me
        WHERE me.id = auth.uid()
          AND (
                me.role = 'super_admin'
                OR (me.role = 'principal' AND EXISTS (
                        SELECT 1 FROM public.users s
                        WHERE s.id = p_student_id AND s.college_id = me.college_id))
                OR (me.role = 'hod' AND EXISTS (
                        SELECT 1 FROM public.users s
                        WHERE s.id = p_student_id AND s.department_id = me.department_id))
                OR (me.role IN ('class_teacher', 'faculty') AND (
                        EXISTS (
                            SELECT 1 FROM public.classes c
                            JOIN public.enrollments e ON e.class_id = c.id
                            WHERE c.class_teacher_id = me.id AND e.student_id = p_student_id)
                        OR EXISTS (
                            SELECT 1 FROM public.timetable t
                            JOIN public.enrollments e ON e.class_id = t.class_id
                            WHERE t.faculty_id = me.id AND e.student_id = p_student_id)))
              )
    );
$$;

-- ---------------------------------------------------------------------------
-- 2) Department-wise Summary
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.get_department_attendance_summary(
    p_from DATE DEFAULT NULL,
    p_to   DATE DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_from   DATE := COALESCE(p_from, (CURRENT_DATE - INTERVAL '6 months')::date);
    v_to     DATE := COALESCE(p_to, CURRENT_DATE);
    v_result JSON;
BEGIN
    SELECT COALESCE(json_agg(row_to_json(r) ORDER BY r.department_name), '[]'::json)
      INTO v_result
    FROM (
        WITH scoped AS (
            SELECT u.id AS student_id
            FROM public.users u
            WHERE u.role = 'student'
              AND public.is_student_in_scope(u.id)
        ),
        scoped_enrollments AS (
            SELECT e.student_id, e.class_id, c.department_id
            FROM public.enrollments e
            JOIN public.classes c ON c.id = e.class_id
            WHERE e.student_id IN (SELECT student_id FROM scoped)
        ),
        sess AS (
            SELECT s.id AS session_id,
                   COALESCE(s.class_id, t.class_id) AS class_id
            FROM public.attendance_sessions s
            LEFT JOIN public.timetable t ON t.id = s.timetable_id
            WHERE COALESCE(s.date, s.created_at::date) BETWEEN v_from AND v_to
        ),
        -- Each student's own class lectures = the denominator they owe.
        per_student AS (
            SELECT se.department_id,
                   se.student_id,
                   COUNT(DISTINCT ss.session_id) AS total_sessions,
                   COUNT(DISTINCT ar.session_id) AS attended
            FROM scoped_enrollments se
            LEFT JOIN sess ss ON ss.class_id = se.class_id
            LEFT JOIN public.attendance_records ar
                   ON ar.session_id = ss.session_id
                  AND ar.student_id = se.student_id
            GROUP BY se.department_id, se.student_id
        ),
        dept_students AS (
            SELECT p.department_id,
                   COUNT(*)                        AS students,
                   SUM(p.total_sessions)           AS expected,
                   SUM(p.attended)                 AS attendances,
                   AVG(CASE WHEN p.total_sessions > 0
                            THEN (p.attended::numeric / p.total_sessions) * 100
                            ELSE NULL END)         AS avg_student_pct
            FROM per_student p
            GROUP BY p.department_id
        ),
        dept_lectures AS (
            SELECT c.department_id, COUNT(DISTINCT ss.session_id) AS lectures_held
            FROM sess ss
            JOIN public.classes c ON c.id = ss.class_id
            WHERE ss.class_id IN (SELECT class_id FROM scoped_enrollments)
            GROUP BY c.department_id
        )
        SELECT
            d.id                                AS department_id,
            d.name::text                        AS department_name,
            COALESCE(ds.students, 0)            AS students,
            COALESCE(dl.lectures_held, 0)       AS lectures_held,
            COALESCE(ds.attendances, 0)         AS attendances,
            COALESCE(ds.expected, 0)            AS expected,
            CASE WHEN COALESCE(ds.expected, 0) > 0
                 THEN ROUND((ds.attendances::numeric / ds.expected) * 100, 1)
                 ELSE 0 END                     AS attendance_pct,
            COALESCE(ROUND(ds.avg_student_pct, 1), 0) AS avg_student_pct
        FROM public.departments d
        LEFT JOIN dept_students  ds ON ds.department_id = d.id
        LEFT JOIN dept_lectures dl ON dl.department_id = d.id
        WHERE ds.department_id IS NOT NULL OR dl.department_id IS NOT NULL
        ORDER BY d.name
    ) r;

    RETURN v_result;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3) Subject-wise Summary
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.get_subject_attendance_summary(
    p_from DATE DEFAULT NULL,
    p_to   DATE DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_from   DATE := COALESCE(p_from, (CURRENT_DATE - INTERVAL '6 months')::date);
    v_to     DATE := COALESCE(p_to, CURRENT_DATE);
    v_result JSON;
BEGIN
    SELECT COALESCE(json_agg(row_to_json(r) ORDER BY r.department_name, r.subject_code), '[]'::json)
      INTO v_result
    FROM (
        WITH scoped AS (
            SELECT u.id AS student_id
            FROM public.users u
            WHERE u.role = 'student'
              AND public.is_student_in_scope(u.id)
        ),
        scoped_enrollments AS (
            SELECT e.student_id, e.class_id
            FROM public.enrollments e
            WHERE e.student_id IN (SELECT student_id FROM scoped)
        ),
        sess AS (
            SELECT s.id AS session_id,
                   COALESCE(s.class_id,   t.class_id)   AS class_id,
                   COALESCE(s.subject_id, t.subject_id) AS subject_id
            FROM public.attendance_sessions s
            LEFT JOIN public.timetable t ON t.id = s.timetable_id
            WHERE COALESCE(s.date, s.created_at::date) BETWEEN v_from AND v_to
        ),
        -- Subjects taught to classes containing scoped students. Two sources:
        -- the timetable, and sessions carrying subject_id directly (ad-hoc
        -- "Take Class" with no timetable row).
        subject_of_class AS (
            SELECT DISTINCT t.class_id, t.subject_id
            FROM public.timetable t
            WHERE t.subject_id IS NOT NULL
              AND t.class_id IN (SELECT class_id FROM scoped_enrollments)
            UNION
            SELECT DISTINCT ss.class_id, ss.subject_id
            FROM sess ss
            WHERE ss.subject_id IS NOT NULL
              AND ss.class_id IN (SELECT class_id FROM scoped_enrollments)
        ),
        per_student AS (
            SELECT soc.subject_id,
                   se.student_id,
                   COUNT(DISTINCT ss.session_id) AS total_sessions,
                   COUNT(DISTINCT ar.session_id) AS attended
            FROM scoped_enrollments se
            JOIN subject_of_class soc ON soc.class_id = se.class_id
            LEFT JOIN sess ss
                   ON ss.class_id = se.class_id
                  AND ss.subject_id = soc.subject_id
            LEFT JOIN public.attendance_records ar
                   ON ar.session_id = ss.session_id
                  AND ar.student_id = se.student_id
            GROUP BY soc.subject_id, se.student_id
        ),
        subject_students AS (
            SELECT p.subject_id,
                   COUNT(*)                  AS students,
                   SUM(p.total_sessions)     AS expected,
                   SUM(p.attended)           AS attendances,
                   AVG(CASE WHEN p.total_sessions > 0
                            THEN (p.attended::numeric / p.total_sessions) * 100
                            ELSE NULL END)   AS avg_student_pct
            FROM per_student p
            GROUP BY p.subject_id
        ),
        subject_lectures AS (
            SELECT ss.subject_id, COUNT(DISTINCT ss.session_id) AS lectures_held
            FROM sess ss
            WHERE ss.subject_id IS NOT NULL
              AND ss.class_id IN (SELECT class_id FROM scoped_enrollments)
            GROUP BY ss.subject_id
        )
        SELECT
            sub.id                              AS subject_id,
            sub.code::text                      AS subject_code,
            sub.name::text                      AS subject_name,
            COALESCE(d.name, 'Unassigned')::text AS department_name,
            COALESCE(sstu.students, 0)          AS students,
            COALESCE(slec.lectures_held, 0)     AS lectures_held,
            COALESCE(sstu.attendances, 0)       AS attendances,
            COALESCE(sstu.expected, 0)          AS expected,
            CASE WHEN COALESCE(sstu.expected, 0) > 0
                 THEN ROUND((sstu.attendances::numeric / sstu.expected) * 100, 1)
                 ELSE 0 END                     AS attendance_pct,
            COALESCE(ROUND(sstu.avg_student_pct, 1), 0) AS avg_student_pct
        FROM public.subjects sub
        JOIN subject_students sstu ON sstu.subject_id = sub.id
        LEFT JOIN subject_lectures slec ON slec.subject_id = sub.id
        LEFT JOIN public.departments d  ON d.id = sub.department_id
        ORDER BY d.name, sub.code
    ) r;

    RETURN v_result;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4) Monthly Attendance Log
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.get_monthly_attendance_log(
    p_from DATE DEFAULT NULL,
    p_to   DATE DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_from   DATE := COALESCE(p_from, (CURRENT_DATE - INTERVAL '6 months')::date);
    v_to     DATE := COALESCE(p_to, CURRENT_DATE);
    v_result JSON;
BEGIN
    SELECT COALESCE(json_agg(row_to_json(r) ORDER BY r.month_start DESC), '[]'::json)
      INTO v_result
    FROM (
        WITH scoped AS (
            SELECT u.id AS student_id
            FROM public.users u
            WHERE u.role = 'student'
              AND public.is_student_in_scope(u.id)
        ),
        scoped_enrollments AS (
            SELECT e.student_id, e.class_id
            FROM public.enrollments e
            WHERE e.student_id IN (SELECT student_id FROM scoped)
        ),
        sess AS (
            SELECT s.id AS session_id,
                   COALESCE(s.class_id, t.class_id) AS class_id,
                   date_trunc('month', COALESCE(s.date, s.created_at::date)) AS month_start
            FROM public.attendance_sessions s
            LEFT JOIN public.timetable t ON t.id = s.timetable_id
            WHERE COALESCE(s.date, s.created_at::date) BETWEEN v_from AND v_to
        ),
        per_student_month AS (
            SELECT ss.month_start,
                   se.student_id,
                   COUNT(DISTINCT ss.session_id) AS total_sessions,
                   COUNT(DISTINCT ar.session_id) AS attended
            FROM scoped_enrollments se
            JOIN sess ss ON ss.class_id = se.class_id
            LEFT JOIN public.attendance_records ar
                   ON ar.session_id = ss.session_id
                  AND ar.student_id = se.student_id
            GROUP BY ss.month_start, se.student_id
        ),
        month_stats AS (
            SELECT p.month_start,
                   COUNT(DISTINCT p.student_id) AS students,
                   SUM(p.total_sessions)        AS expected,
                   SUM(p.attended)              AS attendances,
                   AVG(CASE WHEN p.total_sessions > 0
                            THEN (p.attended::numeric / p.total_sessions) * 100
                            ELSE NULL END)      AS avg_student_pct
            FROM per_student_month p
            GROUP BY p.month_start
        ),
        month_lectures AS (
            SELECT ss.month_start, COUNT(DISTINCT ss.session_id) AS lectures_held
            FROM sess ss
            WHERE ss.class_id IN (SELECT class_id FROM scoped_enrollments)
            GROUP BY ss.month_start
        )
        SELECT
            ml.month_start::date                     AS month_start,
            to_char(ml.month_start, 'Mon YYYY')      AS month_label,
            COALESCE(ms.students, 0)                 AS students,
            ml.lectures_held                         AS lectures_held,
            COALESCE(ms.attendances, 0)              AS attendances,
            COALESCE(ms.expected, 0)                 AS expected,
            CASE WHEN COALESCE(ms.expected, 0) > 0
                 THEN ROUND((ms.attendances::numeric / ms.expected) * 100, 1)
                 ELSE 0 END                          AS attendance_pct,
            COALESCE(ROUND(ms.avg_student_pct, 1), 0) AS avg_student_pct
        FROM month_lectures ml
        LEFT JOIN month_stats ms ON ms.month_start = ml.month_start
        ORDER BY ml.month_start DESC
    ) r;

    RETURN v_result;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5) Fix get_faculty_defaulters: it allowed principal/hod to see defaulters
--    from EVERY college/department. Reuse the same scope helper.
--    Note: this reads the student_attendance_stats materialized view, which
--    only refreshes when a session is closed, so it lags by one lecture.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.get_faculty_defaulters(p_threshold INT)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_result JSON;
BEGIN
    SELECT json_agg(row_to_json(stats)) INTO v_result
    FROM (
        SELECT s.*
        FROM public.student_attendance_stats s
        WHERE s.attendance_percentage < p_threshold
          AND public.is_student_in_scope(s.student_id)
        ORDER BY s.attendance_percentage ASC
        LIMIT 100
    ) stats;

    RETURN COALESCE(v_result, '[]'::json);
END;
$$;

-- ---------------------------------------------------------------------------
-- Grants: authenticated users only (anon is rejected outright)
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.is_student_in_scope(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_department_attendance_summary(DATE, DATE) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_subject_attendance_summary(DATE, DATE) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_monthly_attendance_log(DATE, DATE) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_faculty_defaulters(INT) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.is_student_in_scope(UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_department_attendance_summary(DATE, DATE) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_subject_attendance_summary(DATE, DATE) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_monthly_attendance_log(DATE, DATE) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_faculty_defaulters(INT) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
