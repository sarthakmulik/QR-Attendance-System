-- THE GOD PATCH: Global RLS Recursion Eradication

-------------------------------------------------------------------------------
-- 1. BEDROCK SECURITY FUNCTIONS
-- These run as SECURITY DEFINER to bypass RLS and prevent infinite recursion
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_user_role()
RETURNS user_role AS $$
DECLARE
  v_role user_role;
BEGIN
  SELECT role INTO v_role FROM public.users WHERE id = auth.uid();
  RETURN v_role;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION public.get_user_college_id()
RETURNS UUID AS $$
DECLARE
  v_college_id UUID;
BEGIN
  SELECT college_id INTO v_college_id FROM public.users WHERE id = auth.uid();
  RETURN v_college_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION public.get_user_department_id()
RETURNS UUID AS $$
DECLARE
  v_dept_id UUID;
BEGIN
  SELECT department_id INTO v_dept_id FROM public.users WHERE id = auth.uid();
  RETURN v_dept_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-------------------------------------------------------------------------------
-- 2. DROP ALL EXISTING POLICIES (Cleaning the slate)
-------------------------------------------------------------------------------

-- Users
DROP POLICY IF EXISTS "Super Admins can manage all users" ON public.users;
DROP POLICY IF EXISTS "Users can view themselves" ON public.users;
DROP POLICY IF EXISTS "Dept Admins can manage users in their college" ON public.users;

-- Colleges
DROP POLICY IF EXISTS "Super Admins can manage colleges" ON public.colleges;
DROP POLICY IF EXISTS "Users can view their own college" ON public.colleges;

-- Departments
DROP POLICY IF EXISTS "Super Admins can manage departments" ON public.departments;
DROP POLICY IF EXISTS "Dept Admins can view and manage their college departments" ON public.departments;
DROP POLICY IF EXISTS "Users can view departments in their college" ON public.departments;

-- Phase 3 Tables
DROP POLICY IF EXISTS "Public read for active academic years" ON public.academic_years;
DROP POLICY IF EXISTS "Super Admins can manage academic years" ON public.academic_years;

DROP POLICY IF EXISTS "Everyone can read subjects" ON public.subjects;
DROP POLICY IF EXISTS "Dept Admins can manage subjects" ON public.subjects;

DROP POLICY IF EXISTS "Everyone can read classes" ON public.classes;
DROP POLICY IF EXISTS "Dept Admins can manage classes" ON public.classes;

DROP POLICY IF EXISTS "Everyone can read enrollments" ON public.enrollments;
DROP POLICY IF EXISTS "Teachers can manage enrollments" ON public.enrollments;

DROP POLICY IF EXISTS "Everyone can read timetable" ON public.timetable;
DROP POLICY IF EXISTS "Dept Admins can manage timetable" ON public.timetable;

-- Invites
DROP POLICY IF EXISTS "Admins can manage invites" ON public.user_invites;
DROP POLICY IF EXISTS "Super Admins can manage all invites" ON public.user_invites;
DROP POLICY IF EXISTS "Dept Admins can only invite faculty and students to their college" ON public.user_invites;


-------------------------------------------------------------------------------
-- 3. RECREATE POLICIES (Using strictly safe functions)
-------------------------------------------------------------------------------

-- USERS TABLE
CREATE POLICY "Super Admins can manage all users" ON public.users FOR ALL
USING ( public.get_user_role() = 'super_admin' );

CREATE POLICY "Dept Admins can manage users in their college" ON public.users FOR ALL
USING ( 
    public.get_user_role() = 'dept_admin' 
    AND college_id = public.get_user_college_id() 
)
WITH CHECK ( 
    public.get_user_role() = 'dept_admin' 
    AND college_id = public.get_user_college_id() 
);

CREATE POLICY "Users can view themselves" ON public.users FOR SELECT
USING ( id = auth.uid() );


-- COLLEGES TABLE
CREATE POLICY "Super Admins can manage colleges" ON public.colleges FOR ALL
USING ( public.get_user_role() = 'super_admin' );

CREATE POLICY "Users can view their own college" ON public.colleges FOR SELECT
USING ( id = public.get_user_college_id() );


-- DEPARTMENTS TABLE
CREATE POLICY "Super Admins can manage departments" ON public.departments FOR ALL
USING ( public.get_user_role() = 'super_admin' );

CREATE POLICY "Dept Admins can view and manage their college departments" ON public.departments FOR ALL
USING ( 
    public.get_user_role() = 'dept_admin' 
    AND college_id = public.get_user_college_id() 
);

CREATE POLICY "Users can view departments in their college" ON public.departments FOR SELECT
USING ( college_id = public.get_user_college_id() );


-- USER INVITES TABLE
CREATE POLICY "Super Admins can manage all invites" ON public.user_invites FOR ALL
USING ( public.get_user_role() = 'super_admin' );

CREATE POLICY "Dept Admins can manage invites for their college" ON public.user_invites FOR ALL
USING ( 
    public.get_user_role() = 'dept_admin' 
    AND college_id = public.get_user_college_id()
)
WITH CHECK (
    public.get_user_role() = 'dept_admin' 
    AND role IN ('faculty', 'student')
    AND college_id = public.get_user_college_id()
);


-- ACADEMIC YEARS
CREATE POLICY "Public read for active academic years" ON public.academic_years FOR SELECT USING (true);
CREATE POLICY "Super Admins can manage academic years" ON public.academic_years FOR ALL 
USING ( public.get_user_role() = 'super_admin' );


-- SUBJECTS
CREATE POLICY "Everyone can read subjects" ON public.subjects FOR SELECT USING (true);
CREATE POLICY "Dept Admins can manage subjects" ON public.subjects FOR ALL 
USING ( public.get_user_role() IN ('super_admin', 'dept_admin') );


-- CLASSES
CREATE POLICY "Everyone can read classes" ON public.classes FOR SELECT USING (true);
CREATE POLICY "Dept Admins can manage classes" ON public.classes FOR ALL 
USING ( public.get_user_role() IN ('super_admin', 'dept_admin') );


-- ENROLLMENTS
CREATE POLICY "Everyone can read enrollments" ON public.enrollments FOR SELECT USING (true);
CREATE POLICY "Teachers can manage enrollments" ON public.enrollments FOR ALL 
USING ( public.get_user_role() IN ('super_admin', 'dept_admin', 'faculty') );


-- TIMETABLE
CREATE POLICY "Everyone can read timetable" ON public.timetable FOR SELECT USING (true);
CREATE POLICY "Dept Admins can manage timetable" ON public.timetable FOR ALL 
USING ( public.get_user_role() IN ('super_admin', 'dept_admin') );

