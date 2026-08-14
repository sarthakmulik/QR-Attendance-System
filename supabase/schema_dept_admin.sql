-- RLS Policy Patch for Dept Admin User Management

-- Create a policy allowing Dept Admins to manage and view users strictly within their own college
CREATE POLICY "Dept Admins can manage users in their college"
    ON public.users
    FOR ALL
    USING (
        public.get_user_role() = 'dept_admin'
        AND college_id = (SELECT college_id FROM public.users WHERE id = auth.uid())
    )
    WITH CHECK (
        public.get_user_role() = 'dept_admin'
        AND college_id = (SELECT college_id FROM public.users WHERE id = auth.uid())
    );
