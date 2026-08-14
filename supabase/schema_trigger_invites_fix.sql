-- Drop the existing trigger and function first
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
DROP FUNCTION IF EXISTS public.handle_new_user();

-- Create an improved, robust version of the function that INCLUDES Invites
CREATE OR REPLACE FUNCTION public.handle_new_user() 
RETURNS TRIGGER AS $$
DECLARE
  invite_record RECORD;
  extracted_role text;
  final_role public.user_role;
BEGIN
  -- 1. Check if the email exists in our staging area (user_invites)
  SELECT * INTO invite_record FROM public.user_invites WHERE email = new.email;
  
  IF FOUND THEN
    -- A) Pre-invited User: Use the exact role, college, and department from the invite
    INSERT INTO public.users (id, email, first_name, last_name, role, college_id, department_id)
    VALUES (
      new.id, 
      new.email, 
      COALESCE(NULLIF(new.raw_user_meta_data->>'first_name', ''), 'New'),
      COALESCE(NULLIF(new.raw_user_meta_data->>'last_name', ''), 'User'),
      invite_record.role,
      invite_record.college_id,
      invite_record.department_id
    );
    
    -- Clean up the invite so it's not lingering
    DELETE FROM public.user_invites WHERE email = new.email;
    
  ELSE
    -- B) Normal organic signup (no invite)
    -- Safely extract the role from metadata (handles empty strings or missing keys)
    extracted_role := NULLIF(new.raw_user_meta_data->>'role', '');
    
    BEGIN
      IF extracted_role IS NOT NULL THEN
        final_role := extracted_role::public.user_role;
      ELSE
        final_role := 'student'::public.user_role;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      -- If the cast fails (e.g. invalid role string), fallback to student
      final_role := 'student'::public.user_role;
    END;

    INSERT INTO public.users (id, email, first_name, last_name, role)
    VALUES (
      new.id, 
      COALESCE(new.email, new.phone, 'no-email-' || new.id::text),
      COALESCE(NULLIF(new.raw_user_meta_data->>'first_name', ''), 'New'),
      COALESCE(NULLIF(new.raw_user_meta_data->>'last_name', ''), 'User'),
      final_role
    );
  END IF;

  RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Recreate the trigger
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();
