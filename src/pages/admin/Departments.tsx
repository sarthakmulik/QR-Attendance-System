import { useState, useMemo } from 'react'
import { Plus, MoreVertical, Building, Loader2, GraduationCap, Users as UsersIcon } from 'lucide-react'
import { Card } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from '@/components/ui/dialog'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Accordion, AccordionContent, AccordionItem, AccordionTrigger } from '@/components/ui/accordion'
import { useForm, Controller } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useDepartments, useColleges, useClasses, useUsers } from '@/hooks/queries'
import { useAuth } from '@/context/AuthContext'
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuTrigger } from '@/components/ui/dropdown-menu'

const departmentSchema = z.object({
  college_id: z.string().optional(),
  name: z.string().min(2, 'Name is too short'),
  code: z.string().min(2, 'Code is required').max(10),
})
type DepartmentFormValues = z.infer<typeof departmentSchema>

const classSchema = z.object({
  department_id: z.string(),
  name: z.string().min(1, 'Course/Degree Name is required'),
  semester: z.string().transform((val) => parseInt(val, 10)),
  division: z.string().min(1, 'Division is required'),
  class_teacher_id: z.string().optional().nullable(),
})
type ClassFormValues = z.infer<typeof classSchema>

export default function Departments() {
  const { userRole, userCollegeId, userDepartmentId } = useAuth()
  const [isDeptDialogOpen, setIsDeptDialogOpen] = useState(false)
  
  // Class Modal State
  const [isClassDialogOpen, setIsClassDialogOpen] = useState(false)
  const [activeDeptForClass, setActiveDeptForClass] = useState<string>('')

  const queryClient = useQueryClient()
  const { data: departments, isLoading: isDeptLoading } = useDepartments()
  const { data: colleges } = useColleges()
  const { data: classes, isLoading: isClassesLoading } = useClasses()
  const { data: users } = useUsers()

  const deptForm = useForm<DepartmentFormValues>({
    resolver: zodResolver(departmentSchema),
    defaultValues: { college_id: '', name: '', code: '' },
  })

  const classForm = useForm<ClassFormValues>({
    resolver: zodResolver(classSchema),
    defaultValues: { department_id: '', name: '', semester: 1 as any, division: '', class_teacher_id: null },
  })

  const facultyList = useMemo(() => {
    if (!users) return []
    return users.filter((u: any) => 
      (u.role === 'faculty' || u.role === 'class_teacher') && 
      u.departments?.name // Ensure they have a department
    )
  }, [users])

  const createDepartmentMutation = useMutation({
    mutationFn: async (values: DepartmentFormValues) => {
      const { data, error } = await supabase
        .from('departments')
        .insert({
          college_id: userRole === 'super_admin' ? values.college_id : userCollegeId,
          name: values.name,
          code: values.code,
        })
      if (error) throw error
      return data
    },
    onSuccess: () => {
      toast.success('Department created successfully')
      queryClient.invalidateQueries({ queryKey: ['departments'] })
      setIsDeptDialogOpen(false)
      deptForm.reset()
    },
    onError: (error: any) => toast.error(error.message || 'Failed to create department'),
  })

  const deleteDepartmentMutation = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('departments').delete().eq('id', id)
      if (error) throw error
    },
    onSuccess: () => {
      toast.success('Department deleted')
      queryClient.invalidateQueries({ queryKey: ['departments'] })
    },
    onError: (error: any) => toast.error(error.message || 'Failed to delete department'),
  })

  const createClassMutation = useMutation({
    mutationFn: async (values: ClassFormValues) => {
      const { data, error } = await supabase.from('classes').insert(values)
      if (error) throw error
      return data
    },
    onSuccess: () => {
      toast.success('Class created successfully')
      queryClient.invalidateQueries({ queryKey: ['classes'] })
      setIsClassDialogOpen(false)
      classForm.reset()
    },
    onError: (error: any) => toast.error(error.message || 'Failed to create class'),
  })

  const deleteClassMutation = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('classes').delete().eq('id', id)
      if (error) throw error
    },
    onSuccess: () => {
      toast.success('Class deleted')
      queryClient.invalidateQueries({ queryKey: ['classes'] })
    },
    onError: (error: any) => toast.error(error.message || 'Failed to delete class'),
  })

  const handleOpenClassModal = (deptId: string) => {
    setActiveDeptForClass(deptId)
    classForm.reset({ department_id: deptId, name: '', semester: 1 as any, division: '', class_teacher_id: null })
    setIsClassDialogOpen(true)
  }

  // Filter departments for HOD
  const visibleDepartments = useMemo(() => {
    if (!departments) return []
    if (userRole === 'hod') {
      return departments.filter((d: any) => d.id === userDepartmentId)
    }
    return departments
  }, [departments, userRole, userDepartmentId])

  return (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-slate-900 dark:text-white tracking-tight">Departments & Classes</h1>
          <p className="text-slate-500 text-sm mt-1">Manage academic departments and their respective classrooms.</p>
        </div>
        
        {/* ADD DEPARTMENT MODAL (Hidden for HODs) */}
        {userRole !== 'hod' && (
          <Dialog open={isDeptDialogOpen} onOpenChange={setIsDeptDialogOpen}>
            <DialogTrigger asChild>
              <Button className="gap-2 shadow-sm">
                <Plus size={16} />
                Add Department
              </Button>
            </DialogTrigger>
            <DialogContent className="sm:max-w-[425px]">
              <form onSubmit={deptForm.handleSubmit((v) => createDepartmentMutation.mutate(v))}>
                <DialogHeader>
                  <DialogTitle>Add New Department</DialogTitle>
                  <DialogDescription>Create a new department under a college.</DialogDescription>
                </DialogHeader>
                <div className="grid gap-4 py-4">
                  {userRole === 'super_admin' && (
                    <div className="space-y-2">
                      <Label htmlFor="college_id">College *</Label>
                      <Controller
                        name="college_id"
                        control={deptForm.control}
                        render={({ field }) => (
                          <Select onValueChange={field.onChange} value={field.value}>
                            <SelectTrigger>
                              <SelectValue placeholder="Select a college" />
                            </SelectTrigger>
                            <SelectContent>
                              {colleges?.map((college: any) => (
                                <SelectItem key={college.id} value={college.id}>{college.name}</SelectItem>
                              ))}
                            </SelectContent>
                          </Select>
                        )}
                      />
                      {deptForm.formState.errors.college_id && (
                        <p className="text-xs text-destructive">{deptForm.formState.errors.college_id.message}</p>
                      )}
                    </div>
                  )}
                  <div className="space-y-2">
                    <Label htmlFor="name">Department Name *</Label>
                    <Input id="name" placeholder="e.g. Computer Science" {...deptForm.register('name')} />
                    {deptForm.formState.errors.name && (
                      <p className="text-xs text-destructive">{deptForm.formState.errors.name.message}</p>
                    )}
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="code">Department Code *</Label>
                    <Input id="code" placeholder="e.g. CS" className="uppercase" {...deptForm.register('code')} />
                    {deptForm.formState.errors.code && (
                      <p className="text-xs text-destructive">{deptForm.formState.errors.code.message}</p>
                    )}
                  </div>
                </div>
                <DialogFooter>
                  <Button type="button" variant="outline" onClick={() => setIsDeptDialogOpen(false)}>Cancel</Button>
                  <Button type="submit" disabled={createDepartmentMutation.isPending}>
                    {createDepartmentMutation.isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                    Save Department
                  </Button>
                </DialogFooter>
              </form>
            </DialogContent>
          </Dialog>
        )}
      </div>

      {/* ADD CLASS MODAL */}
      <Dialog open={isClassDialogOpen} onOpenChange={setIsClassDialogOpen}>
        <DialogContent className="sm:max-w-[425px]">
          <form onSubmit={classForm.handleSubmit((v) => createClassMutation.mutate(v))}>
            <DialogHeader>
              <DialogTitle>Add New Class</DialogTitle>
              <DialogDescription>Create a new classroom and assign a class teacher.</DialogDescription>
            </DialogHeader>
            <div className="grid gap-4 py-4">
              <div className="space-y-2">
                <Label htmlFor="name">Degree / Course Name *</Label>
                <Input id="name" placeholder="e.g. BTech Computer Science" {...classForm.register('name')} />
                {classForm.formState.errors.name && (
                  <p className="text-xs text-destructive">{classForm.formState.errors.name.message}</p>
                )}
              </div>
              <div className="grid grid-cols-2 gap-4">
                <div className="space-y-2">
                  <Label htmlFor="semester">Semester *</Label>
                  <Input id="semester" type="number" min="1" max="10" {...classForm.register('semester')} />
                  {classForm.formState.errors.semester && (
                    <p className="text-xs text-destructive">{classForm.formState.errors.semester.message}</p>
                  )}
                </div>
                <div className="space-y-2">
                  <Label htmlFor="division">Division / Section *</Label>
                  <Input id="division" placeholder="e.g. A" className="uppercase" {...classForm.register('division')} />
                  {classForm.formState.errors.division && (
                    <p className="text-xs text-destructive">{classForm.formState.errors.division.message}</p>
                  )}
                </div>
              </div>
              <div className="space-y-2">
                <Label htmlFor="class_teacher_id">Class Teacher (Optional)</Label>
                <Controller
                  name="class_teacher_id"
                  control={classForm.control}
                  render={({ field }) => (
                    <Select onValueChange={field.onChange} value={field.value || undefined}>
                      <SelectTrigger>
                        <SelectValue placeholder="Select faculty" />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="none">-- Unassigned --</SelectItem>
                        {facultyList.filter((f: any) => f.departments?.name && f.departments.id === activeDeptForClass).map((faculty: any) => (
                          <SelectItem key={faculty.id} value={faculty.id}>
                            {faculty.first_name} {faculty.last_name} ({faculty.email})
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  )}
                />
              </div>
            </div>
            <DialogFooter>
              <Button type="button" variant="outline" onClick={() => setIsClassDialogOpen(false)}>Cancel</Button>
              <Button type="submit" disabled={createClassMutation.isPending}>
                {createClassMutation.isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                Save Class
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>

      {/* PREMIUM ACCORDION VIEW FOR DEPARTMENTS */}
      {isDeptLoading || isClassesLoading ? (
        <div className="flex flex-col items-center justify-center py-12 text-slate-500">
          <Loader2 className="w-8 h-8 animate-spin text-primary mb-4" />
          <p>Loading departments...</p>
        </div>
      ) : visibleDepartments.length === 0 ? (
        <Card className="border-none shadow-sm flex flex-col items-center justify-center p-12">
          <div className="bg-slate-100 dark:bg-slate-900 p-4 rounded-full mb-4">
            <Building className="w-8 h-8 text-slate-400" />
          </div>
          <h3 className="text-lg font-semibold text-slate-900 dark:text-white">No departments found</h3>
          <p className="text-slate-500 mt-1">Get started by creating your first department.</p>
        </Card>
      ) : (
        <Accordion type="multiple" className="space-y-4" defaultValue={visibleDepartments.map((d: any) => d.id)}>
          {visibleDepartments.map((dept: any) => {
            const deptClasses = classes?.filter((c: any) => c.department_id === dept.id) || []

            return (
              <AccordionItem key={dept.id} value={dept.id} className="relative border-none bg-white dark:bg-slate-950 rounded-xl shadow-sm overflow-hidden px-2">
                <AccordionTrigger className="hover:no-underline px-4 py-5 group">
                  <div className="flex items-center justify-between w-full pr-4">
                    <div className="flex items-center gap-4">
                      <div className="w-12 h-12 rounded-xl bg-indigo-50 dark:bg-indigo-900/30 flex items-center justify-center text-indigo-600 dark:text-indigo-400 group-hover:scale-105 transition-transform">
                        <Building size={24} />
                      </div>
                      <div className="text-left">
                        <h3 className="text-lg font-semibold text-slate-900 dark:text-white">{dept.name}</h3>
                        <div className="flex items-center gap-2 mt-1">
                          <span className="text-xs font-mono bg-slate-100 dark:bg-slate-800 px-2 py-0.5 rounded text-slate-600 dark:text-slate-400">
                            {dept.code}
                          </span>
                          <span className="text-xs text-slate-500">• {dept.colleges?.name}</span>
                        </div>
                      </div>
                    </div>
                    <div className="flex items-center gap-4" onClick={(e) => e.stopPropagation()}>
                      {userRole !== 'hod' && (
                        <DropdownMenu>
                          <DropdownMenuTrigger asChild>
                            <Button variant="ghost" size="icon" className="text-slate-400 hover:text-slate-600">
                              <MoreVertical size={16} />
                            </Button>
                          </DropdownMenuTrigger>
                          <DropdownMenuContent align="end" className="w-48">
                            <DropdownMenuItem 
                              onClick={() => deleteDepartmentMutation.mutate(dept.id)}
                              className="text-rose-600 focus:text-rose-600 focus:bg-rose-50"
                            >
                              Delete Department
                            </DropdownMenuItem>
                          </DropdownMenuContent>
                        </DropdownMenu>
                      )}
                    </div>
                  </div>
                </AccordionTrigger>
                
                <AccordionContent className="px-4 pb-6">
                  <div className="border-t border-slate-100 dark:border-slate-800 pt-4 mt-2">
                    <div className="flex items-center justify-between mb-4">
                      <h4 className="text-sm font-semibold text-slate-700 dark:text-slate-300 flex items-center gap-2">
                        <GraduationCap size={16} />
                        Classes in this Department
                      </h4>
                      <Button size="sm" variant="secondary" className="gap-2" onClick={() => handleOpenClassModal(dept.id)}>
                        <Plus size={14} /> Add Class
                      </Button>
                    </div>

                    {deptClasses.length === 0 ? (
                      <div className="bg-slate-50 dark:bg-slate-900/50 rounded-lg p-6 text-center border border-dashed border-slate-200 dark:border-slate-800">
                        <p className="text-sm text-slate-500">No classes defined yet.</p>
                      </div>
                    ) : (
                      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                        {deptClasses.map((cls: any) => {
                          const teacher = users?.find((u: any) => u.id === cls.class_teacher_id)
                          return (
                            <div key={cls.id} className="relative group bg-slate-50 dark:bg-slate-900/50 rounded-lg p-4 border border-slate-100 dark:border-slate-800 hover:border-indigo-200 dark:hover:border-indigo-800 transition-colors">
                              <Button 
                                variant="ghost" 
                                size="icon" 
                                className="absolute top-2 right-2 opacity-0 group-hover:opacity-100 text-slate-400 hover:text-rose-600 transition-opacity"
                                onClick={() => deleteClassMutation.mutate(cls.id)}
                              >
                                <MoreVertical size={14} />
                              </Button>
                              <div className="flex items-start gap-3">
                                <div className="w-10 h-10 rounded-lg bg-white dark:bg-slate-800 shadow-sm flex items-center justify-center font-bold text-slate-700 dark:text-slate-300">
                                  {cls.division || '-'}
                                </div>
                                <div>
                                  <h5 className="font-semibold text-slate-900 dark:text-white pr-6">{cls.name}</h5>
                                  <p className="text-xs text-slate-500 mb-2">Semester {cls.semester}</p>
                                  
                                  <div className="flex items-center gap-1.5 text-xs text-slate-600 dark:text-slate-400">
                                    <UsersIcon size={12} className="text-indigo-500" />
                                    {teacher ? `${teacher.first_name} ${teacher.last_name}` : <span className="text-amber-500 italic">No Teacher Assigned</span>}
                                  </div>
                                </div>
                              </div>
                            </div>
                          )
                        })}
                      </div>
                    )}
                  </div>
                </AccordionContent>
              </AccordionItem>
            )
          })}
        </Accordion>
      )}
    </div>
  )
}
