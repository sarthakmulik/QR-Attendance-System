-- Create Enums
CREATE TYPE user_role AS ENUM ('super_admin', 'dept_admin', 'class_teacher', 'faculty', 'student');

-- Table: Colleges
CREATE TABLE colleges (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,
    address TEXT,
    contact_email VARCHAR(255),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Table: Departments
CREATE TABLE departments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    college_id UUID REFERENCES colleges(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    code VARCHAR(50) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(college_id, code)
);

-- Table: Users (Extends auth.users)
CREATE TABLE users (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    role user_role NOT NULL DEFAULT 'student',
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    phone VARCHAR(20),
    profile_photo TEXT,
    college_id UUID REFERENCES colleges(id) ON DELETE SET NULL,
    department_id UUID REFERENCES departments(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Turn on RLS
ALTER TABLE colleges ENABLE ROW LEVEL SECURITY;
ALTER TABLE departments ENABLE ROW LEVEL SECURITY;
ALTER TABLE users ENABLE ROW LEVEL SECURITY;

-- Policies for Colleges
-- Super Admins can do everything
CREATE POLICY "Super Admins can manage colleges"
    ON colleges
    FOR ALL
    USING ( (SELECT role FROM users WHERE id = auth.uid()) = 'super_admin' );

-- Everyone else can view their own college
CREATE POLICY "Users can view their own college"
    ON colleges
    FOR SELECT
    USING ( id = (SELECT college_id FROM users WHERE id = auth.uid()) );

-- Policies for Departments
CREATE POLICY "Super Admins can manage departments"
    ON departments
    FOR ALL
    USING ( (SELECT role FROM users WHERE id = auth.uid()) = 'super_admin' );

CREATE POLICY "Dept Admins can view and manage their college departments"
    ON departments
    FOR ALL
    USING ( 
        (SELECT role FROM users WHERE id = auth.uid()) = 'dept_admin' 
        AND college_id = (SELECT college_id FROM users WHERE id = auth.uid()) 
    );

CREATE POLICY "Users can view their own department"
    ON departments
    FOR SELECT
    USING ( id = (SELECT department_id FROM users WHERE id = auth.uid()) );

-- Policies for Users
CREATE POLICY "Super Admins can manage all users"
    ON users
    FOR ALL
    USING ( (SELECT role FROM users WHERE id = auth.uid()) = 'super_admin' );

CREATE POLICY "Users can view themselves"
    ON users
    FOR SELECT
    USING ( id = auth.uid() );

CREATE POLICY "Users can update themselves"
    ON users
    FOR UPDATE
    USING ( id = auth.uid() );

-- Function to handle new user creation from auth.users
CREATE OR REPLACE FUNCTION public.handle_new_user() 
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.users (id, email, first_name, last_name, role)
  VALUES (
    new.id, 
    new.email, 
    COALESCE(new.raw_user_meta_data->>'first_name', 'New'),
    COALESCE(new.raw_user_meta_data->>'last_name', 'User'),
    COALESCE((new.raw_user_meta_data->>'role')::user_role, 'student'::user_role)
  );
  RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger to automatically create a profile in the users table
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();
