-- Phase 5: Student Dashboard & Reports Views

-- 1. View: Overall Student Attendance Stats
-- Calculates the total sessions held for a student's enrolled classes and how many they attended.
CREATE OR REPLACE VIEW student_attendance_stats AS
SELECT 
    u.id AS student_id,
    u.first_name,
    u.last_name,
    u.email,
    u.college_id,
    u.department_id,
    COUNT(DISTINCT asess.id) AS total_sessions,
    COUNT(DISTINCT ar.session_id) AS attended_sessions,
    CASE 
        WHEN COUNT(DISTINCT asess.id) > 0 THEN 
            ROUND((COUNT(DISTINCT ar.session_id)::numeric / COUNT(DISTINCT asess.id)::numeric) * 100, 2)
        ELSE 0
    END AS attendance_percentage
FROM users u
JOIN enrollments e ON u.id = e.student_id
JOIN classes c ON e.class_id = c.id
LEFT JOIN timetable t ON t.class_id = c.id
LEFT JOIN attendance_sessions asess ON asess.timetable_id = t.id
LEFT JOIN attendance_records ar ON ar.session_id = asess.id AND ar.student_id = u.id
WHERE u.role = 'student'
GROUP BY u.id, u.first_name, u.last_name, u.email, u.college_id, u.department_id;


-- 2. View: Subject-wise Student Attendance Stats
-- Breaks down the attendance percentage per subject for each student.
CREATE OR REPLACE VIEW subject_attendance_stats AS
SELECT 
    u.id AS student_id,
    sub.id AS subject_id,
    sub.name AS subject_name,
    sub.code AS subject_code,
    COUNT(DISTINCT asess.id) AS total_sessions,
    COUNT(DISTINCT ar.session_id) AS attended_sessions,
    CASE 
        WHEN COUNT(DISTINCT asess.id) > 0 THEN 
            ROUND((COUNT(DISTINCT ar.session_id)::numeric / COUNT(DISTINCT asess.id)::numeric) * 100, 2)
        ELSE 0
    END AS attendance_percentage
FROM users u
JOIN enrollments e ON u.id = e.student_id
JOIN classes c ON e.class_id = c.id
JOIN timetable t ON t.class_id = c.id
JOIN subjects sub ON t.subject_id = sub.id
LEFT JOIN attendance_sessions asess ON asess.timetable_id = t.id
LEFT JOIN attendance_records ar ON ar.session_id = asess.id AND ar.student_id = u.id
WHERE u.role = 'student'
GROUP BY u.id, sub.id, sub.name, sub.code;
