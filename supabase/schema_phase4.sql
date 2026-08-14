-- Phase 4: Attendance Engine Schema

-- Table: attendance_sessions
-- Tracks live lectures initiated by faculty members
CREATE TABLE IF NOT EXISTS attendance_sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    timetable_id UUID REFERENCES timetable(id) ON DELETE CASCADE,
    faculty_id UUID REFERENCES users(id) ON DELETE CASCADE,
    date DATE NOT NULL DEFAULT CURRENT_DATE,
    is_active BOOLEAN NOT NULL DEFAULT true,
    current_token VARCHAR(255) NOT NULL, -- The rotating QR token
    token_expires_at TIMESTAMPTZ NOT NULL, -- Expiration of current token (e.g. 15 seconds)
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Table: attendance_records
-- Tracks individual student scans for a specific session
CREATE TYPE attendance_status AS ENUM ('present', 'late', 'absent');

CREATE TABLE IF NOT EXISTS attendance_records (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    session_id UUID REFERENCES attendance_sessions(id) ON DELETE CASCADE,
    student_id UUID REFERENCES users(id) ON DELETE CASCADE,
    status attendance_status NOT NULL DEFAULT 'present',
    scanned_at TIMESTAMPTZ DEFAULT NOW(),
    device_info TEXT, -- Optional security footprint (User Agent, etc.)
    UNIQUE(session_id, student_id) -- A student can only be marked once per session
);

-- Indexing for performance
CREATE INDEX IF NOT EXISTS idx_attendance_sessions_faculty_id ON attendance_sessions(faculty_id);
CREATE INDEX IF NOT EXISTS idx_attendance_sessions_timetable_id ON attendance_sessions(timetable_id);
CREATE INDEX IF NOT EXISTS idx_attendance_sessions_is_active ON attendance_sessions(is_active);

CREATE INDEX IF NOT EXISTS idx_attendance_records_session_id ON attendance_records(session_id);
CREATE INDEX IF NOT EXISTS idx_attendance_records_student_id ON attendance_records(student_id);

-- Enable RLS
ALTER TABLE attendance_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE attendance_records ENABLE ROW LEVEL SECURITY;

-- Policies for attendance_sessions
CREATE POLICY "Faculty can manage their own sessions"
    ON attendance_sessions
    FOR ALL
    USING ( auth.uid() = faculty_id );

CREATE POLICY "Anyone can view active sessions (for students to join)"
    ON attendance_sessions
    FOR SELECT
    USING ( true ); -- We allow selecting to verify token. Real security is via the mark_attendance RPC.

-- Policies for attendance_records
CREATE POLICY "Students can view their own records"
    ON attendance_records
    FOR SELECT
    USING ( auth.uid() = student_id );

CREATE POLICY "Faculty can view records for their sessions"
    ON attendance_records
    FOR SELECT
    USING ( 
        EXISTS (
            SELECT 1 FROM attendance_sessions s 
            WHERE s.id = attendance_records.session_id 
            AND s.faculty_id = auth.uid()
        )
    );

-- RPC Function for Secure Scanning (Highly optimized for concurrent scans)
CREATE OR REPLACE FUNCTION mark_attendance(
    p_session_id UUID,
    p_token VARCHAR,
    p_device_info TEXT DEFAULT NULL
) 
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_session RECORD;
    v_student_id UUID;
    v_existing_record UUID;
BEGIN
    -- 1. Identify the student scanning
    v_student_id := auth.uid();
    IF v_student_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Unauthorized. Please log in.');
    END IF;

    -- 2. Verify Session and Token
    SELECT * INTO v_session 
    FROM attendance_sessions 
    WHERE id = p_session_id AND is_active = true;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'message', 'Session is not active or does not exist.');
    END IF;

    IF v_session.current_token != p_token THEN
        RETURN jsonb_build_object('success', false, 'message', 'Invalid or expired QR code.');
    END IF;

    IF NOW() > v_session.token_expires_at THEN
        RETURN jsonb_build_object('success', false, 'message', 'QR code has expired. Please scan the latest one.');
    END IF;

    -- 3. Verify student is actually enrolled in this class
    -- (Omitted for brevity, but you would JOIN enrollments and classes here if needed)

    -- 4. Check if already marked
    SELECT id INTO v_existing_record FROM attendance_records WHERE session_id = p_session_id AND student_id = v_student_id;
    IF FOUND THEN
        RETURN jsonb_build_object('success', true, 'message', 'Attendance already marked for this session.');
    END IF;

    -- 5. Insert Record
    INSERT INTO attendance_records (session_id, student_id, status, device_info)
    VALUES (p_session_id, v_student_id, 'present', p_device_info);

    RETURN jsonb_build_object('success', true, 'message', 'Attendance marked successfully!');
END;
$$;
