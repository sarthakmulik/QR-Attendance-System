-- Drop the old overloaded invite_or_claim_user function

DROP FUNCTION IF EXISTS public.invite_or_claim_user(
    p_email VARCHAR(255),
    p_role user_role,
    p_college_id UUID,
    p_department_id UUID,
    p_first_name VARCHAR(100),
    p_last_name VARCHAR(100)
);
