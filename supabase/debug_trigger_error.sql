-- Run this in the Supabase SQL Editor to see the EXACT error message 
-- that is causing your Auth Trigger to fail:

DO $$
DECLARE
  new_user_id uuid := uuid_generate_v4();
BEGIN
  -- Insert into auth.users (this will fire the handle_new_user trigger)
  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password, 
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data, 
    created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token
  )
  VALUES (
    new_user_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'debug_auth_test@example.com', '', 
    now(), '{"provider":"email","providers":["email"]}', '{}', 
    now(), now(), '', '', '', ''
  );
  
  RAISE NOTICE 'Insert successful! The trigger is working perfectly.';
  
  -- Clean up the test user
  DELETE FROM auth.users WHERE id = new_user_id;
  
EXCEPTION WHEN OTHERS THEN
  -- Print the exact error message that PostgreSQL is throwing during the Trigger execution
  RAISE EXCEPTION 'TRIGGER FAILED: % (SQLSTATE: %)', SQLERRM, SQLSTATE;
END;
$$;
