-- Database Optimizations for High Traffic

-- 1. Indexes for Foreign Keys and Lookups
-- These significantly speed up JOINs and WHERE clauses on heavily queried tables.
CREATE INDEX IF NOT EXISTS idx_users_college_id ON users(college_id);
CREATE INDEX IF NOT EXISTS idx_users_department_id ON users(department_id);
CREATE INDEX IF NOT EXISTS idx_users_role ON users(role);

CREATE INDEX IF NOT EXISTS idx_departments_college_id ON departments(college_id);

CREATE INDEX IF NOT EXISTS idx_subjects_department_id ON subjects(department_id);
CREATE INDEX IF NOT EXISTS idx_subjects_semester ON subjects(semester);

CREATE INDEX IF NOT EXISTS idx_classes_department_id ON classes(department_id);
CREATE INDEX IF NOT EXISTS idx_classes_academic_year_id ON classes(academic_year_id);
CREATE INDEX IF NOT EXISTS idx_classes_semester ON classes(semester);

CREATE INDEX IF NOT EXISTS idx_enrollments_student_id ON enrollments(student_id);
CREATE INDEX IF NOT EXISTS idx_enrollments_class_id ON enrollments(class_id);

CREATE INDEX IF NOT EXISTS idx_timetable_class_id ON timetable(class_id);
CREATE INDEX IF NOT EXISTS idx_timetable_faculty_id ON timetable(faculty_id);
CREATE INDEX IF NOT EXISTS idx_timetable_day_of_week ON timetable(day_of_week);

-- 2. Materialized View for Timetable (Optional Advanced Optimization)
-- If timetable reads become a bottleneck, you can use a materialized view.
-- For now, the b-tree indexes above will handle thousands of concurrent queries easily in Postgres.

-- 3. Update RLS Performance
-- RLS can sometimes be slow if it queries another table. 
-- We can create a function to get the current user's role to cache it during the transaction.

CREATE OR REPLACE FUNCTION get_current_user_role()
RETURNS text
LANGUAGE sql STABLE
AS $$
  SELECT role::text FROM users WHERE id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION get_current_user_college_id()
RETURNS uuid
LANGUAGE sql STABLE
AS $$
  SELECT college_id FROM users WHERE id = auth.uid();
$$;

-- Example of optimized RLS policy using the STABLE function:
-- DROP POLICY IF EXISTS "Super Admins can manage colleges" ON colleges;
-- CREATE POLICY "Super Admins can manage colleges"
--    ON colleges
--    FOR ALL
--    USING ( get_current_user_role() = 'super_admin' );
