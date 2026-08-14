-- Table: user_invites (Staging area for pre-assigning roles)
CREATE TABLE IF NOT EXISTS public.user_invites (
    email VARCHAR(255) PRIMARY KEY,
    role user_role NOT NULL,
    college_id UUID REFERENCES colleges(id) ON DELETE CASCADE,
    department_id UUID REFERENCES departments(id) ON DELETE CASCADE,
    created_by UUID REFERENCES auth.users(id),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Turn on RLS for invites
ALTER TABLE public.user_invites ENABLE ROW LEVEL SECURITY;

-- Policy: Only Super Admins and Dept Admins can manage invites
CREATE POLICY "Admins can manage invites"
    ON public.user_invites
    FOR ALL
    USING ( public.get_user_role() IN ('super_admin', 'dept_admin') );

-- Update the handle_new_user function to automatically assign roles based on invites
CREATE OR REPLACE FUNCTION public.handle_new_user() 
RETURNS TRIGGER AS $$
DECLARE
  invite_record RECORD;
BEGIN
  -- Check if the email exists in the user_invites table
  SELECT * INTO invite_record FROM public.user_invites WHERE email = new.email;
  
  IF FOUND THEN
    -- If an invite exists, assign the predefined role and affiliations
    INSERT INTO public.users (id, email, first_name, last_name, role, college_id, department_id)
    VALUES (
      new.id, 
      new.email, 
      COALESCE(new.raw_user_meta_data->>'first_name', 'New'),
      COALESCE(new.raw_user_meta_data->>'last_name', 'User'),
      invite_record.role,
      invite_record.college_id,
      invite_record.department_id
    );
    -- Delete the invite so it's not lingering
    DELETE FROM public.user_invites WHERE email = new.email;
  ELSE
    -- If no invite, fallback to the default (student)
    INSERT INTO public.users (id, email, first_name, last_name, role)
    VALUES (
      new.id, 
      new.email, 
      COALESCE(new.raw_user_meta_data->>'first_name', 'New'),
      COALESCE(new.raw_user_meta_data->>'last_name', 'User'),
      COALESCE((new.raw_user_meta_data->>'role')::user_role, 'student'::user_role)
    );
  END IF;

  RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- RPC: create_college_with_admin
-- Creates a college and automatically stages a dept_admin invite if an email is provided
CREATE OR REPLACE FUNCTION public.create_college_with_admin(
    p_name VARCHAR(255),
    p_address TEXT,
    p_contact_email VARCHAR(255)
) RETURNS json AS $$
DECLARE
    new_college_id UUID;
    result json;
BEGIN
    -- Check permissions
    IF public.get_user_role() != 'super_admin' THEN
        RAISE EXCEPTION 'Only super admins can create colleges';
    END IF;

    -- Insert college
    INSERT INTO public.colleges (name, address, contact_email)
    VALUES (p_name, p_address, p_contact_email)
    RETURNING id INTO new_college_id;

    -- If contact email provided, stage an invite
    IF p_contact_email IS NOT NULL AND p_contact_email != '' THEN
        INSERT INTO public.user_invites (email, role, college_id, created_by)
        VALUES (p_contact_email, 'dept_admin'::user_role, new_college_id, auth.uid())
        ON CONFLICT (email) DO UPDATE 
        SET role = 'dept_admin'::user_role, college_id = new_college_id;
    END IF;

    -- Return the inserted college as JSON
    SELECT row_to_json(c) INTO result FROM public.colleges c WHERE id = new_college_id;
    RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
