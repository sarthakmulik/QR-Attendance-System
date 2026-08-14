import os

file_path = r"c:\Attendance-system\src\pages\admin\Users.tsx"

with open(file_path, "r", encoding="utf-8") as f:
    content = f.read()

# 1. Update imports
if "useClasses" not in content:
    content = content.replace("useUserHierarchy, useColleges, useDepartments", "useUserHierarchy, useColleges, useDepartments, useClasses")

# 2. Update schema
old_schema = """const editRoleSchema = z.object({
  role: z.enum(['super_admin', 'principal', 'hod', 'class_teacher', 'faculty', 'student']),
  department_id: z.string().optional().nullable(),
})"""
new_schema = """const editRoleSchema = z.object({
  role: z.enum(['super_admin', 'principal', 'hod', 'class_teacher', 'faculty', 'student']),
  department_id: z.string().optional().nullable(),
  class_id: z.string().optional().nullable(),
  roll_number: z.string().optional().nullable(),
})"""
content = content.replace(old_schema, new_schema)

# 3. Add useClasses hook
old_hook = "const { data: departments } = useDepartments()"
new_hook = "const { data: departments } = useDepartments()\n  const { data: classes } = useClasses()"
if "useClasses()" not in content:
    content = content.replace(old_hook, new_hook)

# 4. Add the JSX for class_id and roll_number when role === 'student'
# Find the department select box to insert after it.
jsx_insert_point = content.find("</div>\n              )}", content.find("Label htmlFor=\"department_id\"")) + len("</div>\n              )}")
new_jsx = """
              {/* ENROLLMENT FIELDS FOR STUDENTS */}
              {selectedEditRole === 'student' && (
                <div className="space-y-4 animate-in fade-in zoom-in-95 mt-4">
                  <div className="space-y-2">
                    <Label htmlFor="class_id">Class / Classroom</Label>
                    <Controller
                      name="class_id"
                      control={editForm.control}
                      render={({ field }) => (
                        <Select onValueChange={field.onChange} value={field.value || undefined}>
                          <SelectTrigger>
                            <SelectValue placeholder="Select a class" />
                          </SelectTrigger>
                          <SelectContent>
                            {classes?.filter((c: any) => c.department_id === (editingUser?.department_id || userDepartmentId)).map((cls: any) => (
                              <SelectItem key={cls.id} value={cls.id}>
                                {cls.name} (Sem {cls.semester})
                              </SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                      )}
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="roll_number">Roll Number</Label>
                    <Input 
                      id="roll_number" 
                      placeholder="e.g. CS2024-001" 
                      {...editForm.register('roll_number')} 
                    />
                  </div>
                </div>
              )}
"""
content = content[:jsx_insert_point] + new_jsx + content[jsx_insert_point:]

# 5. Update the mutation logic
old_mutation = """      mutationFn: async (values: EditRoleFormValues & { userId: string }) => {
        const updateData: any = { role: values.role }
        
        // If role requires a department, ensure it's passed or keep it null.
        // If role does NOT require a department, strictly set it to null.
        if (values.role === 'super_admin' || values.role === 'principal' || values.role === 'student') {
           updateData.department_id = null
        } else {
           updateData.department_id = values.department_id || null
        }

        const { error } = await supabase
          .from('users')
          .update(updateData)
          .eq('id', values.userId)
        
        if (error) throw error
      },"""

new_mutation = """      mutationFn: async (values: EditRoleFormValues & { userId: string }) => {
        const updateData: any = { role: values.role }
        
        if (values.role === 'super_admin' || values.role === 'principal' || values.role === 'student') {
           updateData.department_id = null
        } else {
           updateData.department_id = values.department_id || null
        }

        // 1. Update basic user role
        const { error } = await supabase
          .from('users')
          .update(updateData)
          .eq('id', values.userId)
        
        if (error) throw error

        // 2. If student, execute enrollment upsert RPC
        if (values.role === 'student' && values.class_id && values.roll_number) {
           const { error: rpcError } = await supabase.rpc('enroll_student', {
              p_student_id: values.userId,
              p_class_id: values.class_id,
              p_roll_number: values.roll_number
           })
           if (rpcError) throw rpcError
        }
      },"""
content = content.replace(old_mutation, new_mutation)

# 6. Pre-fill edit form correctly in UserTreeView prop
old_edit_reset = "editForm.reset({ role: user.role, department_id: user.departments?.id || null })"
new_edit_reset = "editForm.reset({ role: user.role, department_id: user.departments?.id || null, class_id: user.class_id || null, roll_number: user.roll_number || '' })"
content = content.replace(old_edit_reset, new_edit_reset)

with open(file_path, "w", encoding="utf-8") as f:
    f.write(content)

print("Updated Users.tsx")
