-- Drop the existing trigger and function first
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
DROP FUNCTION IF EXISTS public.handle_new_user();

-- Create an improved, robust version of the function
CREATE OR REPLACE FUNCTION public.handle_new_user() 
RETURNS TRIGGER AS $$
DECLARE
  extracted_role text;
  final_role public.user_role;
BEGIN
  -- Safely extract the role from metadata (handles empty strings or missing keys)
  extracted_role := NULLIF(new.raw_user_meta_data->>'role', '');
  
  -- Try to cast the extracted role, fallback to 'student'
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

  -- Insert the user profile
  INSERT INTO public.users (id, email, first_name, last_name, role)
  VALUES (
    new.id, 
    COALESCE(new.email, new.phone, 'no-email-' || new.id::text), -- Fallback if email is missing (e.g. phone auth)
    COALESCE(NULLIF(new.raw_user_meta_data->>'first_name', ''), 'New'),
    COALESCE(NULLIF(new.raw_user_meta_data->>'last_name', ''), 'User'),
    final_role
  );
  
  RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Recreate the trigger
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();
