-- Security Patch: Privilege Escalation Lockdown on user_invites

-- 1. Drop the old insecure policy
DROP POLICY IF EXISTS "Admins can manage invites" ON public.user_invites;

-- 2. Create strictly isolated policy for Super Admins
CREATE POLICY "Super Admins can manage all invites"
    ON public.user_invites
    FOR ALL
    USING ( public.get_user_role() = 'super_admin' )
    WITH CHECK ( public.get_user_role() = 'super_admin' );

-- 3. Create strictly isolated and confined policy for Department Admins
-- They can ONLY invite faculty and students, and ONLY into their exact college.
CREATE POLICY "Dept Admins can only invite faculty and students to their college"
    ON public.user_invites
    FOR ALL
    USING ( 
        public.get_user_role() = 'dept_admin' 
        AND college_id = (SELECT college_id FROM public.users WHERE id = auth.uid())
    )
    WITH CHECK (
        public.get_user_role() = 'dept_admin' 
        AND role IN ('faculty', 'student')
        AND college_id = (SELECT college_id FROM public.users WHERE id = auth.uid())
    );
