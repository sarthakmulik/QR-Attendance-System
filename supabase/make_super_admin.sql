-- Run this in your Supabase SQL Editor to forcefully promote an account to Super Admin
UPDATE public.users 
SET role = 'super_admin'::user_role 
WHERE email = 'sarthakmulik16@gmail.com';

-- To verify it worked, run this:
SELECT email, role FROM public.users WHERE email = 'sarthakmulik16@gmail.com';
