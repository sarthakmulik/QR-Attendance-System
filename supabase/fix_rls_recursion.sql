-- Fix Infinite Recursion in RLS Policies (Corrected Schema)

-- 1. Drop existing problematic policies
DROP POLICY IF EXISTS "Super Admins can manage all users" ON users;
DROP POLICY IF EXISTS "Super Admins can manage colleges" ON colleges;
DROP POLICY IF EXISTS "Super Admins can manage departments" ON departments;
DROP POLICY IF EXISTS "Dept Admins can view and manage their college departments" ON departments;

-- 2. Create a SECURITY DEFINER function in the PUBLIC schema
CREATE OR REPLACE FUNCTION public.get_user_role()
RETURNS user_role AS $$
DECLARE
  v_role user_role;
BEGIN
  SELECT role INTO v_role FROM public.users WHERE id = auth.uid();
  RETURN v_role;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 3. Recreate Policies using the safe function

-- Users Table
CREATE POLICY "Super Admins can manage all users"
    ON users
    FOR ALL
    USING ( public.get_user_role() = 'super_admin' );

-- Colleges Table
CREATE POLICY "Super Admins can manage colleges"
    ON colleges
    FOR ALL
    USING ( public.get_user_role() = 'super_admin' );

-- Departments Table
CREATE POLICY "Super Admins can manage departments"
    ON departments
    FOR ALL
    USING ( public.get_user_role() = 'super_admin' );

CREATE POLICY "Dept Admins can view and manage their college departments"
    ON departments
    FOR ALL
    USING ( 
        public.get_user_role() = 'dept_admin' 
        AND college_id = (SELECT college_id FROM users WHERE id = auth.uid()) 
    );
