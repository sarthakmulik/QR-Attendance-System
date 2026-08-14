-- Patch for Users RLS to prevent Privilege Escalation on UPDATE

DROP POLICY IF EXISTS "Dept Admins can manage users in their college" ON public.users;

CREATE POLICY "Dept Admins can manage users in their college" ON public.users FOR ALL
USING ( 
    public.get_user_role() = 'dept_admin' 
    AND college_id = public.get_user_college_id() 
)
WITH CHECK ( 
    public.get_user_role() = 'dept_admin' 
    AND college_id = public.get_user_college_id() 
    AND role IN ('dept_admin', 'faculty', 'student', 'class_teacher')
);
