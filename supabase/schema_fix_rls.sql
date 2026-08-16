-- Migration: Fix RLS Policies for new Roles (principal, hod)

-- 1. Fix Subjects RLS
DROP POLICY IF EXISTS "Dept Admins can manage subjects" ON public.subjects;
CREATE POLICY "Admins and HODs can manage subjects" ON public.subjects FOR ALL USING (
    public.get_user_role() IN ('super_admin', 'principal', 'hod')
);

-- 2. Fix Classes RLS
DROP POLICY IF EXISTS "Dept Admins can manage classes" ON public.classes;
CREATE POLICY "Admins and HODs can manage classes" ON public.classes FOR ALL USING (
    public.get_user_role() IN ('super_admin', 'principal', 'hod')
);

-- 3. Fix Enrollments RLS
DROP POLICY IF EXISTS "Teachers can manage enrollments" ON public.enrollments;
CREATE POLICY "Admins, HODs, and Teachers can manage enrollments" ON public.enrollments FOR ALL USING (
    public.get_user_role() IN ('super_admin', 'principal', 'hod', 'class_teacher')
);

-- 4. Fix Timetable RLS
DROP POLICY IF EXISTS "Dept Admins can manage timetable" ON public.timetable;
CREATE POLICY "Admins and HODs can manage timetable" ON public.timetable FOR ALL USING (
    public.get_user_role() IN ('super_admin', 'principal', 'hod')
);
