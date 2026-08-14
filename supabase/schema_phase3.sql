-- Table: Academic Years
CREATE TABLE academic_years (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(50) NOT NULL,
    start_date DATE,
    end_date DATE,
    is_active BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Table: Subjects
CREATE TABLE subjects (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    department_id UUID REFERENCES departments(id) ON DELETE CASCADE,
    code VARCHAR(50) NOT NULL,
    name VARCHAR(255) NOT NULL,
    credits INTEGER DEFAULT 3,
    semester INTEGER NOT NULL,
    minimum_attendance_pct INTEGER DEFAULT 75,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(department_id, code)
);

-- Table: Classes (Divisions)
CREATE TABLE classes (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    department_id UUID REFERENCES departments(id) ON DELETE CASCADE,
    academic_year_id UUID REFERENCES academic_years(id) ON DELETE RESTRICT,
    name VARCHAR(50) NOT NULL, -- e.g. "A", "B", "SE-IT-A"
    semester INTEGER NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(department_id, academic_year_id, name, semester)
);

-- Table: Student Enrollments (Links students to classes)
CREATE TABLE enrollments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    student_id UUID REFERENCES users(id) ON DELETE CASCADE,
    class_id UUID REFERENCES classes(id) ON DELETE CASCADE,
    roll_number VARCHAR(50),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(student_id, class_id),
    UNIQUE(class_id, roll_number)
);

-- Table: Timetable
CREATE TABLE timetable (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    class_id UUID REFERENCES classes(id) ON DELETE CASCADE,
    subject_id UUID REFERENCES subjects(id) ON DELETE CASCADE,
    faculty_id UUID REFERENCES users(id) ON DELETE RESTRICT,
    day_of_week INTEGER NOT NULL CHECK (day_of_week BETWEEN 1 AND 7), -- 1=Monday
    start_time TIME NOT NULL,
    end_time TIME NOT NULL,
    room_number VARCHAR(50),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- RLS Policies
ALTER TABLE academic_years ENABLE ROW LEVEL SECURITY;
ALTER TABLE subjects ENABLE ROW LEVEL SECURITY;
ALTER TABLE classes ENABLE ROW LEVEL SECURITY;
ALTER TABLE enrollments ENABLE ROW LEVEL SECURITY;
ALTER TABLE timetable ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Public read for active academic years" ON academic_years FOR SELECT USING (true);
CREATE POLICY "Super Admins can manage academic years" ON academic_years FOR ALL USING ((SELECT role FROM users WHERE id = auth.uid()) = 'super_admin');

CREATE POLICY "Everyone can read subjects" ON subjects FOR SELECT USING (true);
CREATE POLICY "Dept Admins can manage subjects" ON subjects FOR ALL USING (
    (SELECT role FROM users WHERE id = auth.uid()) IN ('super_admin', 'dept_admin')
);

CREATE POLICY "Everyone can read classes" ON classes FOR SELECT USING (true);
CREATE POLICY "Dept Admins can manage classes" ON classes FOR ALL USING (
    (SELECT role FROM users WHERE id = auth.uid()) IN ('super_admin', 'dept_admin')
);

CREATE POLICY "Everyone can read enrollments" ON enrollments FOR SELECT USING (true);
CREATE POLICY "Teachers can manage enrollments" ON enrollments FOR ALL USING (
    (SELECT role FROM users WHERE id = auth.uid()) IN ('super_admin', 'dept_admin', 'class_teacher')
);

CREATE POLICY "Everyone can read timetable" ON timetable FOR SELECT USING (true);
CREATE POLICY "Dept Admins can manage timetable" ON timetable FOR ALL USING (
    (SELECT role FROM users WHERE id = auth.uid()) IN ('super_admin', 'dept_admin')
);
