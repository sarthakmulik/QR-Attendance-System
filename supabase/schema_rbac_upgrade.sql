-- RBAC Upgrade: Introduce Principal and HOD roles

-- 1. Safely add new ENUM values
ALTER TYPE user_role ADD VALUE IF NOT EXISTS 'principal';
ALTER TYPE user_role ADD VALUE IF NOT EXISTS 'hod';
COMMIT; -- Note: ALTER TYPE ADD VALUE cannot be executed inside a transaction block in some versions, but if running via Supabase UI it handles it.

-- 2. Migrate existing dept_admin users to principal
UPDATE public.users SET role = 'principal' WHERE role = 'dept_admin';
UPDATE public.user_invites SET role = 'principal' WHERE role = 'dept_admin';

-------------------------------------------------------------------------------
-- 3. GLOBAL RLS POLICY UPGRADES (God Patch V2)
-------------------------------------------------------------------------------

-- Drop old policies to replace them
DROP POLICY IF EXISTS "Super Admins can manage all users" ON public.users;
DROP POLICY IF EXISTS "Dept Admins can manage users in their college" ON public.users;
DROP POLICY IF EXISTS "Users can view themselves" ON public.users;

DROP POLICY IF EXISTS "Super Admins can manage colleges" ON public.colleges;
DROP POLICY IF EXISTS "Users can view their own college" ON public.colleges;

DROP POLICY IF EXISTS "Super Admins can manage departments" ON public.departments;
DROP POLICY IF EXISTS "Dept Admins can view and manage their college departments" ON public.departments;
DROP POLICY IF EXISTS "Users can view departments in their college" ON public.departments;

DROP POLICY IF EXISTS "Super Admins can manage all invites" ON public.user_invites;
DROP POLICY IF EXISTS "Dept Admins can manage invites for their college" ON public.user_invites;
DROP POLICY IF EXISTS "Dept Admins can only invite faculty and students to their college" ON public.user_invites;

DROP POLICY IF EXISTS "Everyone can read subjects" ON public.subjects;
DROP POLICY IF EXISTS "Dept Admins can manage subjects" ON public.subjects;

DROP POLICY IF EXISTS "Everyone can read classes" ON public.classes;
DROP POLICY IF EXISTS "Dept Admins can manage classes" ON public.classes;

DROP POLICY IF EXISTS "Everyone can read enrollments" ON public.enrollments;
DROP POLICY IF EXISTS "Teachers can manage enrollments" ON public.enrollments;

DROP POLICY IF EXISTS "Everyone can read timetable" ON public.timetable;
DROP POLICY IF EXISTS "Dept Admins can manage timetable" ON public.timetable;


-- USERS TABLE
CREATE POLICY "Super Admins can manage all users" ON public.users FOR ALL
USING ( public.get_user_role() = 'super_admin' );

CREATE POLICY "Principals can manage users in their college" ON public.users FOR ALL
USING ( 
    public.get_user_role() = 'principal' 
    AND college_id = public.get_user_college_id() 
)
WITH CHECK ( 
    public.get_user_role() = 'principal' 
    AND college_id = public.get_user_college_id() 
);

CREATE POLICY "HODs can manage users in their department" ON public.users FOR ALL
USING ( 
    public.get_user_role() = 'hod' 
    AND college_id = public.get_user_college_id() 
    AND (department_id = public.get_user_department_id() OR department_id IS NULL)
)
WITH CHECK ( 
    public.get_user_role() = 'hod' 
    AND college_id = public.get_user_college_id() 
    AND department_id = public.get_user_department_id()
    AND role IN ('faculty', 'student')
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

CREATE POLICY "Principals can manage departments in their college" ON public.departments FOR ALL
USING ( 
    public.get_user_role() = 'principal' 
    AND college_id = public.get_user_college_id() 
);

CREATE POLICY "Users can view departments in their college" ON public.departments FOR SELECT
USING ( college_id = public.get_user_college_id() );


-- USER INVITES TABLE
CREATE POLICY "Super Admins can manage all invites" ON public.user_invites FOR ALL
USING ( public.get_user_role() = 'super_admin' );

CREATE POLICY "Principals can manage invites for their college" ON public.user_invites FOR ALL
USING ( 
    public.get_user_role() = 'principal' 
    AND college_id = public.get_user_college_id()
)
WITH CHECK (
    public.get_user_role() = 'principal' 
    AND role IN ('hod', 'faculty', 'student')
    AND college_id = public.get_user_college_id()
);

CREATE POLICY "HODs can manage invites for their department" ON public.user_invites FOR ALL
USING ( 
    public.get_user_role() = 'hod' 
    AND college_id = public.get_user_college_id()
    AND department_id = public.get_user_department_id()
)
WITH CHECK (
    public.get_user_role() = 'hod' 
    AND role IN ('faculty', 'student')
    AND college_id = public.get_user_college_id()
    AND department_id = public.get_user_department_id()
);


-- SUBJECTS
CREATE POLICY "Everyone can read subjects" ON public.subjects FOR SELECT USING (true);

CREATE POLICY "Principals can manage subjects" ON public.subjects FOR ALL 
USING ( 
    public.get_user_role() = 'principal' 
    AND department_id IN (SELECT id FROM public.departments WHERE college_id = public.get_user_college_id())
);

CREATE POLICY "HODs can manage subjects" ON public.subjects FOR ALL 
USING ( 
    public.get_user_role() = 'hod' 
    AND department_id = public.get_user_department_id()
);


-- CLASSES
CREATE POLICY "Everyone can read classes" ON public.classes FOR SELECT USING (true);

CREATE POLICY "Principals can manage classes" ON public.classes FOR ALL 
USING ( 
    public.get_user_role() = 'principal' 
    AND department_id IN (SELECT id FROM public.departments WHERE college_id = public.get_user_college_id())
);

CREATE POLICY "HODs can manage classes" ON public.classes FOR ALL 
USING ( 
    public.get_user_role() = 'hod' 
    AND department_id = public.get_user_department_id()
);


-- ENROLLMENTS
CREATE POLICY "Everyone can read enrollments" ON public.enrollments FOR SELECT USING (true);
CREATE POLICY "Management and Faculty can manage enrollments" ON public.enrollments FOR ALL 
USING ( public.get_user_role() IN ('super_admin', 'principal', 'hod', 'faculty') );


-- TIMETABLE
CREATE POLICY "Everyone can read timetable" ON public.timetable FOR SELECT USING (true);

CREATE POLICY "Principals can manage timetable" ON public.timetable FOR ALL 
USING ( 
    public.get_user_role() = 'principal' 
    AND class_id IN (
        SELECT c.id FROM public.classes c
        JOIN public.departments d ON c.department_id = d.id
        WHERE d.college_id = public.get_user_college_id()
    )
);

CREATE POLICY "HODs can manage timetable" ON public.timetable FOR ALL 
USING ( 
    public.get_user_role() = 'hod' 
    AND class_id IN (
        SELECT id FROM public.classes WHERE department_id = public.get_user_department_id()
    )
);
