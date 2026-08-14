import re
import os

filepath = r"c:\Attendance-system\src\pages\admin\Users.tsx"
with open(filepath, "r", encoding="utf-8") as f:
    content = f.read()

# 1. Add schema for editing role
schema_code = """
const editRoleSchema = z.object({
  role: z.enum(['super_admin', 'principal', 'hod', 'class_teacher', 'faculty', 'student']),
  department_id: z.string().optional().nullable(),
})
type EditRoleFormValues = z.infer<typeof editRoleSchema>
"""
content = content.replace("type UserFormValues = z.infer<typeof userSchema>", "type UserFormValues = z.infer<typeof userSchema>\n" + schema_code)

# 2. Add new states
states_code = """    const [isEditDialogOpen, setIsEditDialogOpen] = useState(false)
    const [editingUser, setEditingUser] = useState<any>(null)

    const editForm = useForm<EditRoleFormValues>({
      resolver: zodResolver(editRoleSchema),
      defaultValues: { role: 'student', department_id: null },
    })

    const selectedEditRole = editForm.watch('role')
"""
content = content.replace("    const [isDialogOpen, setIsDialogOpen] = useState(false)", "    const [isDialogOpen, setIsDialogOpen] = useState(false)\n" + states_code)

# 3. Update updateUserMutation
new_mutation = """  const updateUserMutation = useMutation({
    mutationFn: async (values: EditRoleFormValues & { userId: string }) => {
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
    },
    onSuccess: () => {
      toast.success('User role updated successfully!')
      setIsEditDialogOpen(false)
      queryClient.invalidateQueries({ queryKey: ['users'] })
    },
    onError: (error: any) => {
      toast.error(error.message || 'Failed to update user role')
    }
  })

  const onEditSubmit = (values: EditRoleFormValues) => {
    if (editingUser) {
      updateUserMutation.mutate({ ...values, userId: editingUser.id })
    }
  }
"""

old_mutation_pattern = re.compile(r"const updateUserMutation = useMutation\(\{.*?onError: \(error: any\) => \{.*?\}\s*\}\)", re.DOTALL)
content = old_mutation_pattern.sub(new_mutation.strip(), content)

# 4. Replace DropdownMenuContent
new_dropdown = """<DropdownMenuContent align="end" className="w-48">
                          <DropdownMenuLabel>Actions</DropdownMenuLabel>
                          <DropdownMenuSeparator />
                          <DropdownMenuItem 
                            onClick={() => {
                              setEditingUser(user)
                              editForm.reset({
                                role: user.role,
                                department_id: user.departments?.id || null
                              })
                              setIsEditDialogOpen(true)
                            }}
                          >
                            Edit Role & Department
                          </DropdownMenuItem>
                        </DropdownMenuContent>"""
old_dropdown_pattern = re.compile(r"<DropdownMenuContent align=\"end\" className=\"w-48\">.*?</DropdownMenuContent>", re.DOTALL)
content = old_dropdown_pattern.sub(new_dropdown, content)

# 5. Add the Dialog UI below the existing Dialog
edit_dialog_ui = """

      <Dialog open={isEditDialogOpen} onOpenChange={setIsEditDialogOpen}>
        <DialogContent className="sm:max-w-[425px]">
          <DialogHeader>
            <DialogTitle>Edit User Role</DialogTitle>
            <DialogDescription>
              Assign a new role and department to {editingUser?.first_name} {editingUser?.last_name}.
            </DialogDescription>
          </DialogHeader>
          <form onSubmit={editForm.handleSubmit(onEditSubmit)}>
            <div className="grid gap-4 py-4">
              <div className="space-y-2">
                <Label htmlFor="role">Role</Label>
                <Controller
                  name="role"
                  control={editForm.control}
                  render={({ field }) => (
                    <Select onValueChange={field.onChange} value={field.value}>
                      <SelectTrigger>
                        <SelectValue placeholder="Select a role" />
                      </SelectTrigger>
                      <SelectContent>
                        {userRole === 'super_admin' && (
                          <>
                            <SelectItem value="super_admin">Super Admin</SelectItem>
                            <SelectItem value="principal">Principal</SelectItem>
                          </>
                        )}
                        {(userRole === 'super_admin' || userRole === 'principal') && (
                          <SelectItem value="hod">HOD</SelectItem>
                        )}
                        <SelectItem value="class_teacher">Class Teacher</SelectItem>
                        <SelectItem value="faculty">Faculty</SelectItem>
                        <SelectItem value="student">Student</SelectItem>
                      </SelectContent>
                    </Select>
                  )}
                />
              </div>

              {(selectedEditRole === 'hod' || selectedEditRole === 'class_teacher' || selectedEditRole === 'faculty') && (
                <div className="space-y-2 animate-in fade-in zoom-in-95">
                  <Label htmlFor="department_id">Department (Required for this role)</Label>
                  <Controller
                    name="department_id"
                    control={editForm.control}
                    render={({ field }) => (
                      <Select onValueChange={field.onChange} value={field.value || undefined}>
                        <SelectTrigger>
                          <SelectValue placeholder="Select department" />
                        </SelectTrigger>
                        <SelectContent>
                          {departments?.filter(d => d.college_id === (editingUser?.college_id || userCollegeId)).map((dept) => (
                            <SelectItem key={dept.id} value={dept.id}>
                              {dept.name} ({dept.code})
                            </SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                    )}
                  />
                </div>
              )}

            </div>
            <DialogFooter>
              <Button type="button" variant="outline" onClick={() => setIsEditDialogOpen(false)}>Cancel</Button>
              <Button type="submit" disabled={updateUserMutation.isPending}>
                {updateUserMutation.isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                Save Changes
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
"""

content = content.replace("      <Card className=\"border-none shadow-sm overflow-hidden\">", edit_dialog_ui + "\n      <Card className=\"border-none shadow-sm overflow-hidden\">")

with open(filepath, "w", encoding="utf-8") as f:
    f.write(content)
print("Updated Users.tsx")
