-- Class Teacher RLS Patch
-- This script grants the class_teacher role the ability to manage students in their department

-- 1. Users Table Policy
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

-- 2. User Invites Policy
CREATE POLICY "Class Teachers can invite students to their department" ON public.user_invites FOR ALL
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
