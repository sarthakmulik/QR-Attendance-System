-- Database Patch: Classes Division and Invites Expansion

-- 1. Add division to classes
ALTER TABLE public.classes ADD COLUMN IF NOT EXISTS division VARCHAR(50);

-- 2. Add first_name and last_name to user_invites
ALTER TABLE public.user_invites ADD COLUMN IF NOT EXISTS first_name VARCHAR(100);
ALTER TABLE public.user_invites ADD COLUMN IF NOT EXISTS last_name VARCHAR(100);

-- 3. Update invite_or_claim_user RPC
CREATE OR REPLACE FUNCTION public.invite_or_claim_user(
    p_email VARCHAR(255),
    p_role user_role,
    p_college_id UUID,
    p_department_id UUID DEFAULT NULL,
    p_first_name VARCHAR(100) DEFAULT NULL,
    p_last_name VARCHAR(100) DEFAULT NULL
) RETURNS json AS $$
DECLARE
    existing_user_id UUID;
    caller_role user_role;
    caller_college_id UUID;
    caller_dept_id UUID;
BEGIN
    -- 1. Get the caller's context
    caller_role := public.get_user_role();
    caller_college_id := public.get_user_college_id();
    caller_dept_id := public.get_user_department_id();

    -- 2. Verify Caller Permissions
    IF caller_role = 'student' OR caller_role = 'faculty' THEN
        RAISE EXCEPTION 'Unauthorized: You do not have permission to invite users.';
    END IF;

    IF caller_role = 'principal' THEN
        IF p_college_id != caller_college_id THEN
            RAISE EXCEPTION 'Unauthorized: Principals can only invite users to their own college.';
        END IF;
        IF p_role IN ('super_admin', 'principal') THEN
            RAISE EXCEPTION 'Unauthorized: Principals cannot assign super_admin or principal roles.';
        END IF;
    END IF;

    IF caller_role = 'hod' THEN
        IF p_college_id != caller_college_id OR p_department_id != caller_dept_id THEN
            RAISE EXCEPTION 'Unauthorized: HODs can only invite users to their own department.';
        END IF;
        IF p_role IN ('super_admin', 'principal', 'hod') THEN
            RAISE EXCEPTION 'Unauthorized: HODs cannot assign management roles above class_teacher.';
        END IF;
    END IF;

    IF caller_role = 'class_teacher' THEN
        IF p_college_id != caller_college_id OR p_department_id != caller_dept_id THEN
            RAISE EXCEPTION 'Unauthorized: Class Teachers can only invite users to their own department.';
        END IF;
        IF p_role != 'student' THEN
            RAISE EXCEPTION 'Unauthorized: Class Teachers can only invite students.';
        END IF;
    END IF;

    -- 3. Check if the user already exists organically in public.users
    SELECT id INTO existing_user_id FROM public.users WHERE email = p_email LIMIT 1;

    IF existing_user_id IS NOT NULL THEN
        -- The user already signed up! Update their row directly.
        UPDATE public.users 
        SET 
            role = p_role,
            college_id = p_college_id,
            department_id = p_department_id,
            first_name = COALESCE(p_first_name, first_name),
            last_name = COALESCE(p_last_name, last_name)
        WHERE id = existing_user_id 
        AND (
            (college_id IS NULL AND role = 'student') OR 
            (college_id = caller_college_id) OR
            caller_role = 'super_admin'
        );
        
        -- Also delete any stuck invites just in case
        DELETE FROM public.user_invites WHERE email = p_email;
        
        RETURN json_build_object('status', 'claimed', 'user_id', existing_user_id);
    ELSE
        -- The user hasn't signed up yet. Stage the invite!
        INSERT INTO public.user_invites (email, role, college_id, department_id, created_by, first_name, last_name)
        VALUES (p_email, p_role, p_college_id, p_department_id, auth.uid(), p_first_name, p_last_name)
        ON CONFLICT (email) DO UPDATE 
        SET 
            role = EXCLUDED.role,
            college_id = EXCLUDED.college_id,
            department_id = EXCLUDED.department_id,
            created_by = EXCLUDED.created_by,
            first_name = COALESCE(EXCLUDED.first_name, user_invites.first_name),
            last_name = COALESCE(EXCLUDED.last_name, user_invites.last_name);

        RETURN json_build_object('status', 'invited', 'email', p_email);
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 4. Update the handle_new_user trigger
CREATE OR REPLACE FUNCTION public.handle_new_user() 
RETURNS TRIGGER AS $$
DECLARE
  invite_record RECORD;
BEGIN
  -- Check if the email exists in the user_invites table
  SELECT * INTO invite_record FROM public.user_invites WHERE email = new.email;
  
  IF FOUND THEN
    -- If an invite exists, assign the predefined role and affiliations and Names!
    INSERT INTO public.users (id, email, first_name, last_name, role, college_id, department_id)
    VALUES (
      new.id, 
      new.email, 
      COALESCE(invite_record.first_name, new.raw_user_meta_data->>'first_name', 'New'),
      COALESCE(invite_record.last_name, new.raw_user_meta_data->>'last_name', 'User'),
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
