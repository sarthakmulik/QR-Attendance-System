-- schema_geofencing.sql

-- 1. Add latitude and longitude to classes
ALTER TABLE public.classes ADD COLUMN IF NOT EXISTS latitude FLOAT;
ALTER TABLE public.classes ADD COLUMN IF NOT EXISTS longitude FLOAT;

-- 2. Create Haversine Distance function
CREATE OR REPLACE FUNCTION public.haversine_distance(lat1 FLOAT, lon1 FLOAT, lat2 FLOAT, lon2 FLOAT)
RETURNS FLOAT AS $B
DECLARE
    R FLOAT := 6371000; -- Earth radius in meters
    phi1 FLOAT := radians(lat1);
    phi2 FLOAT := radians(lat2);
    delta_phi FLOAT := radians(lat2 - lat1);
    delta_lambda FLOAT := radians(lon2 - lon1);
    a FLOAT;
    c FLOAT;
BEGIN
    a := sin(delta_phi / 2.0) * sin(delta_phi / 2.0) +
         cos(phi1) * cos(phi2) *
         sin(delta_lambda / 2.0) * sin(delta_lambda / 2.0);
    c := 2.0 * atan2(sqrt(a), sqrt(1.0 - a));
    RETURN R * c;
END;
$B LANGUAGE plpgsql IMMUTABLE;

-- 3. Update mark_attendance RPC
CREATE OR REPLACE FUNCTION public.mark_attendance(
    p_session_id UUID,
    p_token VARCHAR,
    p_device_info TEXT DEFAULT NULL,
    p_lat FLOAT DEFAULT NULL,
    p_lng FLOAT DEFAULT NULL
) 
RETURNS json AS $B
DECLARE
    v_session RECORD;
    v_student_id UUID;
    v_existing_record UUID;
    v_class_lat FLOAT;
    v_class_lng FLOAT;
    v_distance FLOAT;
BEGIN
    -- 1. Identify the student scanning
    v_student_id := auth.uid();
    IF v_student_id IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'Unauthorized. Please log in.');
    END IF;

    -- 2. Verify Session and Token
    SELECT * INTO v_session 
    FROM public.attendance_sessions 
    WHERE id = p_session_id AND is_active = true;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'message', 'Session is not active or does not exist.');
    END IF;

    IF v_session.current_token != p_token THEN
        RETURN json_build_object('success', false, 'message', 'Invalid or expired QR code.');
    END IF;

    IF NOW() > v_session.token_expires_at THEN
        RETURN json_build_object('success', false, 'message', 'QR code has expired. Please scan the latest one.');
    END IF;

    -- 3. Check Geofencing (100 meters)
    -- Get classroom location via timetable -> class
    SELECT c.latitude, c.longitude INTO v_class_lat, v_class_lng
    FROM public.timetable t
    JOIN public.classes c ON c.id = t.class_id
    WHERE t.id = v_session.timetable_id;

    IF v_class_lat IS NULL OR v_class_lng IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'Classroom location has not been set by the Class Teacher. Cannot verify attendance.');
    END IF;

    IF p_lat IS NULL OR p_lng IS NULL THEN
        RETURN json_build_object('success', false, 'message', 'Your GPS location is required to mark attendance.');
    END IF;

    v_distance := public.haversine_distance(p_lat, p_lng, v_class_lat, v_class_lng);
    
    IF v_distance > 100.0 THEN
        RETURN json_build_object('success', false, 'message', 'You are ' || round(v_distance::numeric, 1) || ' meters away. You must be within 100 meters of the classroom.');
    END IF;

    -- 4. Check if already marked
    SELECT id INTO v_existing_record FROM public.attendance_records WHERE session_id = p_session_id AND student_id = v_student_id;
    IF FOUND THEN
        RETURN json_build_object('success', true, 'message', 'Attendance already marked for this session.');
    END IF;

    -- 5. Insert Record
    INSERT INTO public.attendance_records (session_id, student_id, status, device_info)
    VALUES (p_session_id, v_student_id, 'present', p_device_info);

    RETURN json_build_object('success', true, 'message', 'Attendance marked successfully!');
END;
$B LANGUAGE plpgsql SECURITY DEFINER;
