import os
import re

file_path = r"c:\Attendance-system\src\pages\admin\Students.tsx"
with open(file_path, "r", encoding="utf-8") as f:
    content = f.read()

# 1. Update addStudentSchema
old_schema = """const addStudentSchema = z.object({
  email: z.string().email(),
  class_id: z.string().min(1, "Class is required"),
  roll_number: z.string().min(1, "Roll number is required")
})"""
new_schema = """const addStudentSchema = z.object({
  first_name: z.string().min(2, "First name is required"),
  last_name: z.string().min(2, "Last name is required"),
  email: z.string().email(),
  class_id: z.string().min(1, "Class is required"),
  roll_number: z.string().min(1, "Roll number is required")
})"""
content = content.replace(old_schema, new_schema)

# 2. Update defaultValues
old_default = "defaultValues: { email: '', class_id: '', roll_number: '' }"
new_default = "defaultValues: { first_name: '', last_name: '', email: '', class_id: '', roll_number: '' }"
content = content.replace(old_default, new_default)

# 3. Update invite_or_claim_user mutation payload
old_payload = """p_email: values.email,
        p_role: 'student',
        p_college_id: userCollegeId,
        p_department_id: userDepartmentId"""
new_payload = """p_email: values.email,
        p_role: 'student',
        p_college_id: userCollegeId,
        p_department_id: userDepartmentId,
        p_first_name: values.first_name,
        p_last_name: values.last_name"""
content = content.replace(old_payload, new_payload)

# 4. Update the Dialog Form to add First/Last Name inputs
# Insert before email Label
old_email_div = """<div className="space-y-2">
                    <Label htmlFor="email">Email</Label>
                    <Input id="email" type="email" placeholder="student@college.edu" {...addForm.register('email')} />
                  </div>"""

new_names_and_email = """<div className="grid grid-cols-2 gap-4">
                    <div className="space-y-2">
                      <Label htmlFor="first_name">First Name</Label>
                      <Input id="first_name" placeholder="John" {...addForm.register('first_name')} />
                    </div>
                    <div className="space-y-2">
                      <Label htmlFor="last_name">Last Name</Label>
                      <Input id="last_name" placeholder="Doe" {...addForm.register('last_name')} />
                    </div>
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="email">Email</Label>
                    <Input id="email" type="email" placeholder="student@college.edu" {...addForm.register('email')} />
                  </div>"""
content = content.replace(old_email_div, new_names_and_email)

with open(file_path, "w", encoding="utf-8") as f:
    f.write(content)

print("Updated Students.tsx")
