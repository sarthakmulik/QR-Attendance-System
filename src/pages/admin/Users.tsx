import { useState, useMemo } from 'react'
import { Plus, MoreVertical, Users as UsersIcon, Loader2, UserPlus } from 'lucide-react'
import { Card } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from '@/components/ui/dialog'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { useForm, Controller } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useUserHierarchy, useColleges, useDepartments, useClasses } from '@/hooks/queries'
import { UserTreeView } from '@/components/users/UserTreeView'
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuTrigger } from '@/components/ui/dropdown-menu'
import { useAuth } from '@/context/AuthContext'

const userSchema = z.object({
  first_name: z.string().min(2, 'First name is too short'),
  last_name: z.string().min(2, 'Last name is too short'),
  email: z.string().email('Invalid email address'),
  role: z.enum(['super_admin', 'principal', 'hod', 'class_teacher', 'faculty', 'student']),
  college_id: z.string().optional(),
  department_id: z.string().optional(),
  class_id: z.string().optional().nullable(),
})

type UserFormValues = z.infer<typeof userSchema>

const editRoleSchema = z.object({
  role: z.enum(['super_admin', 'principal', 'hod', 'class_teacher', 'faculty', 'student']),
  department_id: z.string().optional().nullable(),
  class_id: z.string().optional().nullable(),
  roll_number: z.string().optional().nullable(),
})
type EditRoleFormValues = z.infer<typeof editRoleSchema>


export default function Users() {
  const { userRole, userCollegeId, userDepartmentId } = useAuth()
  const [isDialogOpen, setIsDialogOpen] = useState(false)
  const [isEditDialogOpen, setIsEditDialogOpen] = useState(false)
  const [editingUser, setEditingUser] = useState<any>(null)

  const editForm = useForm<EditRoleFormValues>({
    resolver: zodResolver(editRoleSchema),
    defaultValues: { role: 'student', department_id: null },
  })

  const selectedEditRole = editForm.watch('role')
  const selectedEditDeptId = editForm.watch('department_id')
  
  const queryClient = useQueryClient()
  const { data: hierarchy, isLoading } = useUserHierarchy()
  const { data: colleges } = useColleges()
  const { data: departments } = useDepartments()
  const { data: classes } = useClasses()

  const availableEditClasses = useMemo(() => {
    if (!classes) return []
    if (selectedEditDeptId) {
      return classes.filter((c: any) => c.department_id === selectedEditDeptId)
    }
    if (userRole === 'super_admin') {
      return classes
    }
    if (userRole === 'principal') {
      const colId = editingUser?.college_id || userCollegeId
      return colId ? classes.filter((c: any) => c.departments?.college_id === colId) : classes
    }
    if (userRole === 'hod') {
      const deptId = userDepartmentId || editingUser?.department_id
      return deptId ? classes.filter((c: any) => c.department_id === deptId) : classes
    }
    return classes
  }, [classes, selectedEditDeptId, userRole, userCollegeId, userDepartmentId, editingUser])

  const form = useForm<UserFormValues>({
    resolver: zodResolver(userSchema),
    defaultValues: {
      first_name: '',
      last_name: '',
      email: '',
      role: 'student',
      college_id: '',
      department_id: '',
    },
  })

  // Watch role and college to dynamically filter/show fields
  const selectedRole = form.watch('role')
  const selectedCollege = form.watch('college_id') || userCollegeId

  // Filter departments based on selected or implicit college
  const filteredDepartments = departments?.filter(d => 
    d.college_id === selectedCollege
  ) || []

  const inviteUserMutation = useMutation({
    mutationFn: async (values: UserFormValues) => {
      // Use the secure RPC which handles both claiming existing users and pre-registering new ones seamlessly
      const { data, error } = await supabase.rpc('invite_or_claim_user', {
        p_email: values.email.trim().toLowerCase(),
        p_role: values.role,
        p_college_id: userRole === 'super_admin' ? (values.college_id || null) : userCollegeId,
        p_department_id: (userRole === 'super_admin' || userRole === 'principal') ? (values.department_id || null) : userDepartmentId,
        p_first_name: values.first_name,
        p_last_name: values.last_name,
        p_class_id: values.class_id || null
      })
      
      if (error) throw error
      return data
    },
    onSuccess: (data: any) => {
      if (data?.status === 'staged') {
        toast.success('User pre-registered. Ask them to open Sign up on the login page with this email so their role is assigned.')
      } else {
        toast.success('User added and updated successfully!')
      }
      setIsDialogOpen(false)
      form.reset()
      queryClient.invalidateQueries({ queryKey: ['user-hierarchy'] })
    },
    onError: (error: any) => {
      toast.error(error.message || 'Failed to stage user invite')
    },
  })

  const updateUserMutation = useMutation({
    mutationFn: async (values: EditRoleFormValues & { userId: string, email: string }) => {
      const selectedClass = classes?.find((c: any) => c.id === values.class_id)
      const targetDeptId = values.department_id || selectedClass?.department_id || (userRole === 'hod' ? userDepartmentId : editingUser?.department_id) || null
      const targetCollegeId = userRole === 'super_admin' ? null : (editingUser?.college_id || userCollegeId || selectedClass?.departments?.college_id || null)

      const { data, error } = await supabase.rpc('invite_or_claim_user', {
        p_email: values.email.trim().toLowerCase(),
        p_role: values.role,
        p_college_id: targetCollegeId,
        p_department_id: targetDeptId,
        p_first_name: null, // Keeps existing
        p_last_name: null,  // Keeps existing
        p_class_id: values.class_id && values.class_id !== 'none' ? values.class_id : null,
        p_roll_number: values.roll_number || null
      })
      
      if (error) throw error
      return data
    },
    onSuccess: () => {
      toast.success('User role updated successfully!')
      setIsEditDialogOpen(false)
      queryClient.invalidateQueries({ queryKey: ['user-hierarchy'] })
      queryClient.invalidateQueries({ queryKey: ['users'] })
    },
    onError: (error: any) => {
      toast.error(error.message || 'Failed to update user role')
    },
  })

  const onEditSubmit = (values: EditRoleFormValues) => {
    if (editingUser) {
      updateUserMutation.mutate({ ...values, userId: editingUser.id, email: editingUser.email })
    }
  }

  const onSubmit = (values: UserFormValues) => {
    inviteUserMutation.mutate(values)
  }

  const getRoleBadgeColor = (role: string) => {
    switch(role) {
      case 'super_admin': return 'bg-purple-100 text-purple-700 dark:bg-purple-900/30 dark:text-purple-400'
      case 'principal': return 'bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-400'
      case 'hod': return 'bg-indigo-100 text-indigo-700 dark:bg-indigo-900/30 dark:text-indigo-400'
      case 'class_teacher': return 'bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-400'
      case 'faculty': return 'bg-emerald-100 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-400'
      default: return 'bg-slate-100 text-slate-700 dark:bg-slate-800 dark:text-slate-400'
    }
  }

  const formatRole = (role: string) => {
    if (role === 'hod') return 'HOD'
    return role.split('_').map(w => w.charAt(0).toUpperCase() + w.slice(1)).join(' ')
  }

  return (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-slate-900 dark:text-white tracking-tight">User Management</h1>
          <p className="text-slate-500 text-sm mt-1">Manage all roles and users in the system.</p>
        </div>
        
        <Dialog open={isDialogOpen} onOpenChange={setIsDialogOpen}>
          <DialogTrigger asChild>
            <Button onClick={() => setIsDialogOpen(true)} className="bg-indigo-600 hover:bg-indigo-700 text-white">
              <UserPlus className="mr-2 h-4 w-4" />
              Add User
            </Button>
          </DialogTrigger>
          <DialogContent className="sm:max-w-[425px]">
            <form onSubmit={form.handleSubmit(onSubmit)}>
              <DialogHeader>
                <DialogTitle>Add New User</DialogTitle>
                <DialogDescription>
                  Pre-register a new user and assign their role and department.
                </DialogDescription>
              </DialogHeader>
              <div className="grid gap-4 py-4 max-h-[60vh] overflow-y-auto px-1">
                <div className="grid grid-cols-2 gap-4">
                  <div className="space-y-2">
                    <Label htmlFor="first_name">First Name</Label>
                    <Input id="first_name" placeholder="John" {...form.register('first_name')} />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="last_name">Last Name</Label>
                    <Input id="last_name" placeholder="Doe" {...form.register('last_name')} />
                  </div>
                </div>
                <div className="space-y-2">
                  <Label htmlFor="email">Email Address</Label>
                  <Input id="email" type="email" placeholder="john.doe@example.com" {...form.register('email')} />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="role">System Role</Label>
                  <Controller
                    control={form.control}
                    name="role"
                    render={({ field }) => (
                      <Select onValueChange={field.onChange} defaultValue={field.value}>
                        <SelectTrigger>
                          <SelectValue placeholder="Select role" />
                        </SelectTrigger>
                        <SelectContent>
                          {userRole === 'super_admin' && (
                            <>
                              <SelectItem value="super_admin">Super Admin</SelectItem>
                              <SelectItem value="principal">Principal</SelectItem>
                              <SelectItem value="hod">HOD</SelectItem>
                            </>
                          )}
                          {userRole === 'principal' && (
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

                {selectedRole !== 'super_admin' && userRole === 'super_admin' && (
                  <div className="space-y-2 animate-in fade-in zoom-in-95">
                    <Label htmlFor="college_id">College</Label>
                    <Controller
                      control={form.control}
                      name="college_id"
                      render={({ field }) => (
                        <Select onValueChange={field.onChange} defaultValue={field.value}>
                          <SelectTrigger>
                            <SelectValue placeholder="Select college" />
                          </SelectTrigger>
                          <SelectContent>
                            {colleges?.map((col: any) => (
                              <SelectItem key={col.id} value={col.id}>{col.name}</SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                      )}
                    />
                  </div>
                )}

                {(selectedRole === 'hod' || selectedRole === 'class_teacher' || selectedRole === 'faculty') && selectedCollege && userRole !== 'hod' && (
                  <div className="space-y-2 animate-in fade-in zoom-in-95">
                    <Label htmlFor="department_id">Department</Label>
                    <Controller
                      control={form.control}
                      name="department_id"
                      render={({ field }) => (
                        <Select onValueChange={field.onChange} defaultValue={field.value}>
                          <SelectTrigger>
                            <SelectValue placeholder="Select department" />
                          </SelectTrigger>
                          <SelectContent>
                            {filteredDepartments.map((dept: any) => (
                              <SelectItem key={dept.id} value={dept.id}>{dept.name}</SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                      )}
                    />
                  </div>
                )}

                {selectedRole === 'class_teacher' && selectedCollege && (
                  <div className="space-y-2 animate-in fade-in zoom-in-95">
                    <Label htmlFor="class_id">Assign to Class</Label>
                    <Controller
                      control={form.control}
                      name="class_id"
                      render={({ field }) => (
                        <Select onValueChange={field.onChange} defaultValue={field.value || undefined}>
                          <SelectTrigger>
                            <SelectValue placeholder="Select a class" />
                          </SelectTrigger>
                          <SelectContent>
                            {classes?.filter((c: any) => c.department_id === (form.getValues('department_id') || userDepartmentId)).map((cls: any) => (
                              <SelectItem key={cls.id} value={cls.id}>{cls.name} (Sem {cls.semester})</SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                      )}
                    />
                  </div>
                )}

              </div>
              <DialogFooter>
                <Button type="button" variant="outline" onClick={() => setIsDialogOpen(false)}>Cancel</Button>
                <Button type="submit" disabled={inviteUserMutation.isPending}>
                  {inviteUserMutation.isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                  Add User
                </Button>
              </DialogFooter>
            </form>
          </DialogContent>
        </Dialog>
      </div>



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
                {/* ENROLLMENT FIELDS FOR STUDENTS AND CLASS TEACHERS */}
                {(selectedEditRole === 'student' || selectedEditRole === 'class_teacher') && (
                  <div className="space-y-4 animate-in fade-in zoom-in-95 mt-4">
                    <div className="space-y-2">
                      <Label htmlFor="class_id">{selectedEditRole === 'class_teacher' ? 'Assign to Class' : 'Class / Classroom'}</Label>
                      <Controller
                        name="class_id"
                        control={editForm.control}
                        render={({ field }) => (
                          <Select onValueChange={field.onChange} value={field.value || undefined}>
                            <SelectTrigger>
                              <SelectValue placeholder="Select a class" />
                            </SelectTrigger>
                            <SelectContent>
                              <SelectItem value="none">-- Unassigned --</SelectItem>
                              {availableEditClasses.map((cls: any) => (
                                <SelectItem key={cls.id} value={cls.id}>
                                  {cls.name} (Sem {cls.semester})
                                </SelectItem>
                              ))}
                            </SelectContent>
                          </Select>
                        )}
                      />
                    </div>
                    {selectedEditRole === 'student' && (
                      <div className="space-y-2">
                        <Label htmlFor="roll_number">Roll Number</Label>
                        <Input id="roll_number" placeholder="e.g. CS2024-001" {...editForm.register('roll_number')} />
                      </div>
                    )}
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

      
      {/* Search and Filters are hidden for Tree View for now, but can be added back */}
      {hierarchy ? (
        <UserTreeView 
          hierarchy={hierarchy} 
          userRole={userRole} 
          onEditRole={(user) => {
            setEditingUser(user)
            editForm.reset({ 
              role: user.role, 
              department_id: user.department_id || user.departments?.id || null, 
              class_id: user.class_id || user.assignedClasses?.[0]?.id || null, 
              roll_number: user.roll_number || '' 
            })
            setIsEditDialogOpen(true)
          }} 
        />
      ) : (
        <div className="flex items-center justify-center p-8 text-slate-500">No data available</div>
      )}

    </div>
  )
}
