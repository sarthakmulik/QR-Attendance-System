-- Deep Role Management Fixes

-- 1. Drop the old conflicting policies
DROP POLICY IF EXISTS "Principals can manage users in their college" ON public.users;
DROP POLICY IF EXISTS "HODs can manage users in their department" ON public.users;
DROP POLICY IF EXISTS "Class Teachers can manage students in their department" ON public.users;

-- 2. Create the exact allowed role escalations

-- PRINCIPAL: Can manage hod, class_teacher, faculty, student
CREATE POLICY "Principals can manage users in their college" ON public.users FOR ALL
USING ( 
    public.get_user_role() = 'principal' 
    AND college_id = public.get_user_college_id() 
)
WITH CHECK ( 
    public.get_user_role() = 'principal' 
    AND college_id = public.get_user_college_id() 
    AND role IN ('hod', 'class_teacher', 'faculty', 'student')
);

-- HOD: Can manage class_teacher, faculty, student
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
    AND role IN ('class_teacher', 'faculty', 'student')
);

-- CLASS TEACHER: Can manage only student
CREATE POLICY "Class Teachers can manage students in their department" ON public.users FOR ALL
USING ( 
    public.get_user_role() = 'class_teacher' 
    AND college_id = public.get_user_college_id() 
    AND department_id = public.get_user_department_id()
    AND role = 'student'
)
WITH CHECK ( 
    public.get_user_role() = 'class_teacher' 
    AND college_id = public.get_user_college_id() 
    AND department_id = public.get_user_department_id()
    AND role = 'student'
);
