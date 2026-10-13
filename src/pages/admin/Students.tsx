import { useState, useMemo, useRef } from 'react'
import { Plus, Upload, Search, Loader2, MapPin } from 'lucide-react'
import { Card } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from '@/components/ui/dialog'
import { useUsers, useClasses } from '@/hooks/queries'
import { useAuth } from '@/context/AuthContext'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'
import { z } from 'zod'
import { useForm, Controller } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { useMutation, useQueryClient } from '@tanstack/react-query'

const addStudentSchema = z.object({
  first_name: z.string().min(2, "First name is required"),
  last_name: z.string().min(2, "Last name is required"),
  email: z.string().email(),
  class_id: z.string().min(1, "Class is required"),
  roll_number: z.string().min(1, "Roll number is required")
})
type AddStudentFormValues = z.infer<typeof addStudentSchema>

export default function Students() {
  const { userCollegeId, userDepartmentId, userRole, user } = useAuth()
  const queryClient = useQueryClient()
  
  const [searchQuery, setSearchQuery] = useState('')
  const [isAddDialogOpen, setIsAddDialogOpen] = useState(false)
  const [isImportDialogOpen, setIsImportDialogOpen] = useState(false)
  const [selectedImportClass, setSelectedImportClass] = useState<string>('')
  const [isImporting, setIsImporting] = useState(false)
  const fileInputRef = useRef<HTMLInputElement>(null)

  const { data: users, isLoading } = useUsers()
  const { data: classes } = useClasses()

  const departmentClasses = useMemo(() => {
    if (!classes) return []
    let filtered = classes

    if (userRole === 'super_admin') {
      return filtered
    }
    
    if (userRole === 'principal') {
      return userCollegeId ? filtered.filter(c => c.departments?.college_id === userCollegeId) : filtered
    }
    
    if (userRole === 'hod' || userRole === 'faculty') {
      return userDepartmentId ? filtered.filter(c => c.department_id === userDepartmentId) : filtered
    }

    // RBAC: Class Teachers only see their own explicitly assigned classes
    if (userRole === 'class_teacher') {
      return filtered.filter(c => c.class_teacher_id === user?.id)
    }
    
    return filtered
  }, [classes, userDepartmentId, userCollegeId, userRole, user])

  const students = useMemo(() => {
    if (!users) return []
    return users
      .filter((u: any) => u.role === 'student')
      .filter((u: any) => {
        // RBAC: Class Teachers ONLY see students enrolled in their assigned classes
        if (userRole === 'class_teacher') {
          const isMyStudent = u.enrollments?.some((e: any) => e.classes?.class_teacher_id === user?.id)
          if (!isMyStudent) return false
        }
        return true
      })
      .filter((u: any) => {
        if (!searchQuery) return true
        const q = searchQuery.toLowerCase()
        const rollStr = u.enrollments?.[0]?.roll_number?.toLowerCase() || ''
        return (
          u.first_name?.toLowerCase().includes(q) ||
          u.last_name?.toLowerCase().includes(q) ||
          u.email?.toLowerCase().includes(q) ||
          rollStr.includes(q)
        )
      })
      // Sort by roll number if available
      .sort((a: any, b: any) => {
        const r1 = a.enrollments?.[0]?.roll_number || 'ZZZ'
        const r2 = b.enrollments?.[0]?.roll_number || 'ZZZ'
        return r1.localeCompare(r2)
      })
  }, [users, searchQuery, userRole, user])

  const addForm = useForm<AddStudentFormValues>({
    resolver: zodResolver(addStudentSchema),
    defaultValues: { first_name: '', last_name: '', email: '', class_id: '', roll_number: '' },
  })

  // MUTATION: Add Single Student
  const addStudentMutation = useMutation({
    mutationFn: async (values: AddStudentFormValues) => {
      const targetClass = classes?.find((c: any) => c.id === values.class_id)
      const collegeId = userCollegeId || targetClass?.departments?.college_id || null
      const deptId = userDepartmentId || targetClass?.department_id || null

      const { data: inviteData, error: inviteError } = await supabase.rpc('invite_or_claim_user', {
        p_email: values.email,
        p_role: 'student',
        p_college_id: collegeId,
        p_department_id: deptId,
        p_first_name: values.first_name,
        p_last_name: values.last_name,
        p_class_id: values.class_id,
        p_roll_number: values.roll_number
      })
      if (inviteError) throw inviteError

      return inviteData
    },
    onSuccess: (data: any) => {
      if (data?.status === 'staged') {
        toast.success('Student pre-registered successfully! They will be automatically enrolled when they sign up.')
      } else {
        toast.success('Student added and enrolled successfully!')
      }
      setIsAddDialogOpen(false)
      addForm.reset()
      queryClient.invalidateQueries({ queryKey: ['users'] })
      queryClient.invalidateQueries({ queryKey: ['enrollments'] })
    },
    onError: (error: any) => {
      toast.error(error.message || 'Failed to add student')
    }
  })

  // HANDLER: Bulk CSV Import
  const handleFileUpload = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (!file || !selectedImportClass) return

    setIsImporting(true)
    try {
      const text = await file.text()
      // Basic CSV parse: split by newline, then comma
      const rows = text.split('\n').map(row => row.trim()).filter(row => row.length > 0)
      
      let successCount = 0
      let failCount = 0

      const targetClass = classes?.find((c: any) => c.id === selectedImportClass)
      const collegeId = userCollegeId || targetClass?.departments?.college_id || null
      const deptId = userDepartmentId || targetClass?.department_id || null

      // Process sequentially to avoid hammering the DB
      for (let i = 0; i < rows.length; i++) {
        // Skip header if it contains 'email'
        if (i === 0 && rows[0].toLowerCase().includes('email')) continue;

        // Try parsing email, roll_number, first_name, last_name (optional)
        const columns = rows[i].split(',').map(s => s.trim())
        const email = columns[0]
        const roll_number = columns[1]
        const first_name = columns[2] || 'Student'
        const last_name = columns[3] || 'User'
        
        if (!email || !roll_number) continue;

        try {
          const { error: inviteError } = await supabase.rpc('invite_or_claim_user', {
            p_email: email,
            p_role: 'student',
            p_college_id: collegeId,
            p_department_id: deptId,
            p_first_name: first_name,
            p_last_name: last_name,
            p_class_id: selectedImportClass,
            p_roll_number: roll_number
          })
          if (inviteError) throw inviteError

          successCount++
        } catch (err) {
          console.error(`Failed to import ${email}:`, err)
          failCount++
        }
      }

      toast.success(`Import complete! ${successCount} processed, ${failCount} failed.`)
      setIsImportDialogOpen(false)
      queryClient.invalidateQueries({ queryKey: ['users'] })
      queryClient.invalidateQueries({ queryKey: ['enrollments'] })
    } catch (err) {
      toast.error('Failed to parse CSV file')
    } finally {
      setIsImporting(false)
      if (fileInputRef.current) fileInputRef.current.value = ''
    }
  }

  // GEOLOCATION SETUP
  const [isClassSettingsOpen, setIsClassSettingsOpen] = useState(false)
  const [selectedLocationClass, setSelectedLocationClass] = useState('')
  const [isLocating, setIsLocating] = useState(false)

  const setLocationMutation = useMutation({
    mutationFn: async ({ classId, lat, lng }: { classId: string, lat: number, lng: number }) => {
      const { error } = await supabase
        .from('classes')
        .update({ latitude: lat, longitude: lng })
        .eq('id', classId)
      if (error) throw error
    },
    onSuccess: () => {
      toast.success('Classroom GPS coordinates locked securely!')
      setIsClassSettingsOpen(false)
      queryClient.invalidateQueries({ queryKey: ['classes'] })
    },
    onError: (error: any) => {
      toast.error(error.message || 'Failed to update location')
    }
  })

  const handleSetLocation = () => {
    if (!selectedLocationClass) {
      toast.error('Please select a class first')
      return
    }
    setIsLocating(true)
    if ('geolocation' in navigator) {
      navigator.geolocation.getCurrentPosition(
        (position) => {
          setLocationMutation.mutate({
            classId: selectedLocationClass,
            lat: position.coords.latitude,
            lng: position.coords.longitude
          })
          setIsLocating(false)
        },
        (error) => {
          setIsLocating(false)
          if (error.code === error.PERMISSION_DENIED) {
            toast.error('You must allow Location permissions to set the classroom location.')
          } else {
            toast.error('Failed to get location. Please try again.')
          }
        },
        { enableHighAccuracy: true, timeout: 10000, maximumAge: 0 }
      )
    } else {
      setIsLocating(false)
      toast.error('Geolocation is not supported by your browser.')
    }
  }

  return (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-slate-900 dark:text-white tracking-tight">Student Directory</h1>
          <p className="text-slate-500 text-sm mt-1">Manage enrollments, view profiles, and import students.</p>
        </div>
        <div className="flex gap-2">
          
          {/* GEOLOCATION/CLASS SETTINGS MODAL */}
          {userRole === 'class_teacher' && (
            <Dialog open={isClassSettingsOpen} onOpenChange={setIsClassSettingsOpen}>
              <DialogTrigger asChild>
                <Button variant="outline" className="gap-2 shadow-sm border-indigo-200 text-indigo-700 hover:bg-indigo-50">
                  <MapPin size={16} />
                  Set Classroom Location
                </Button>
              </DialogTrigger>
              <DialogContent>
                <DialogHeader>
                  <DialogTitle>Set Classroom GPS Location</DialogTitle>
                  <DialogDescription>
                    Lock the physical location of your classroom to prevent proxy attendance. 
                    You must physically be in the classroom to do this.
                  </DialogDescription>
                </DialogHeader>
                <div className="space-y-4 py-4">
                  <div className="space-y-2">
                    <Label>Target Class</Label>
                    <Select onValueChange={setSelectedLocationClass} value={selectedLocationClass}>
                      <SelectTrigger>
                        <SelectValue placeholder="Select a class" />
                      </SelectTrigger>
                      <SelectContent>
                        {departmentClasses.map((cls: any) => (
                          <SelectItem key={cls.id} value={cls.id}>
                            {cls.name} (Sem {cls.semester})
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  </div>
                </div>
                <DialogFooter>
                  <Button type="button" variant="outline" onClick={() => setIsClassSettingsOpen(false)}>Cancel</Button>
                  <Button type="button" onClick={handleSetLocation} disabled={isLocating || setLocationMutation.isPending}>
                    {(isLocating || setLocationMutation.isPending) && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                    Lock Location
                  </Button>
                </DialogFooter>
              </DialogContent>
            </Dialog>
          )}

          {/* IMPORT MODAL */}
          <Dialog open={isImportDialogOpen} onOpenChange={setIsImportDialogOpen}>
            <DialogTrigger asChild>
              <Button variant="outline" className="gap-2 shadow-sm">
                <Upload size={16} />
                Bulk Import (CSV)
              </Button>
            </DialogTrigger>
            <DialogContent>
              <DialogHeader>
                <DialogTitle>Bulk Import Students</DialogTitle>
                <DialogDescription>
                  Select the target class, then upload a CSV with two columns: <code>email, roll_number</code>
                </DialogDescription>
              </DialogHeader>
              <div className="space-y-4 py-4">
                <div className="space-y-2">
                  <Label>Target Class</Label>
                    <Select onValueChange={setSelectedImportClass} value={selectedImportClass}>
                      <SelectTrigger>
                        <SelectValue placeholder="Select a class for import" />
                      </SelectTrigger>
                      <SelectContent>
                        {departmentClasses.map((cls: any) => (
                          <SelectItem key={cls.id} value={cls.id}>
                            {cls.name} (Sem {cls.semester})
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                    {departmentClasses.length === 0 && (
                       <p className="text-xs text-orange-500">
                         {userRole === 'class_teacher' 
                           ? "You are not assigned as a Class Teacher to any class yet." 
                           : "No classes available."}
                       </p>
                    )}
                </div>
                <div className="space-y-2">
                  <Label>CSV File</Label>
                  <Input 
                    type="file" 
                    accept=".csv" 
                    disabled={!selectedImportClass || isImporting} 
                    onChange={handleFileUpload}
                    ref={fileInputRef}
                  />
                  {!selectedImportClass && <p className="text-xs text-orange-500">Please select a class first.</p>}
                  {isImporting && <p className="text-xs text-indigo-500 animate-pulse">Importing rows, please wait...</p>}
                </div>
              </div>
            </DialogContent>
          </Dialog>

          {/* ADD STUDENT MODAL */}
          <Dialog open={isAddDialogOpen} onOpenChange={setIsAddDialogOpen}>
            <DialogTrigger asChild>
              <Button className="gap-2 shadow-sm">
                <Plus size={16} />
                Add Student
              </Button>
            </DialogTrigger>
            <DialogContent>
              <form onSubmit={addForm.handleSubmit((values) => addStudentMutation.mutate(values))}>
                <DialogHeader>
                  <DialogTitle>Add Student</DialogTitle>
                  <DialogDescription>
                    Invite a student to a specific class.
                  </DialogDescription>
                </DialogHeader>
                <div className="space-y-4 py-4">
                  <div className="grid grid-cols-2 gap-4">
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
                  </div>
                  <div className="space-y-2">
                    <Label>Class</Label>
                    <Controller
                      control={addForm.control}
                      name="class_id"
                      render={({ field }) => (
                        <div className="space-y-1">
                          <Select onValueChange={field.onChange} value={field.value}>
                            <SelectTrigger>
                              <SelectValue placeholder="Select class" />
                            </SelectTrigger>
                            <SelectContent>
                              {departmentClasses.map((cls: any) => (
                                <SelectItem key={cls.id} value={cls.id}>
                                  {cls.name} (Sem {cls.semester})
                                </SelectItem>
                              ))}
                            </SelectContent>
                          </Select>
                          {departmentClasses.length === 0 && (
                             <p className="text-xs text-orange-500">
                               {userRole === 'class_teacher' 
                                 ? "You are not assigned as a Class Teacher to any class yet." 
                                 : "No classes available."}
                             </p>
                          )}
                        </div>
                      )}
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="roll_number">Roll Number</Label>
                    <Input id="roll_number" placeholder="e.g. CS2024-001" {...addForm.register('roll_number')} />
                  </div>
                </div>
                <DialogFooter>
                  <Button type="button" variant="outline" onClick={() => setIsAddDialogOpen(false)}>Cancel</Button>
                  <Button type="submit" disabled={addStudentMutation.isPending}>
                    {addStudentMutation.isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                    Add Student
                  </Button>
                </DialogFooter>
              </form>
            </DialogContent>
          </Dialog>

        </div>
      </div>

      <Card className="p-4 border-none shadow-sm flex items-center gap-4">
        <div className="relative flex-1">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" size={18} />
          <Input 
            placeholder="Search students by name, email, or roll number..." 
            className="pl-10 bg-slate-50/50 dark:bg-slate-900/50 border-slate-200 dark:border-slate-800"
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
          />
        </div>
      </Card>

      <Card className="border-none shadow-sm overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm text-left">
            <thead className="text-xs text-slate-500 uppercase bg-slate-50 dark:bg-slate-900/50 dark:text-slate-400 border-b border-slate-100 dark:border-slate-800">
              <tr>
                <th className="px-6 py-4 font-medium">Student</th>
                <th className="px-6 py-4 font-medium">Contact</th>
                <th className="px-6 py-4 font-medium">Class / Dept</th>
                <th className="px-6 py-4 font-medium">Joined</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100 dark:divide-slate-800/50">
              {isLoading ? (
                <tr>
                  <td colSpan={4} className="px-6 py-8 text-center text-slate-500">
                    <Loader2 className="h-6 w-6 animate-spin mx-auto mb-2" />
                    Loading students...
                  </td>
                </tr>
              ) : students.length === 0 ? (
                <tr>
                  <td colSpan={4} className="px-6 py-8 text-center text-slate-500">
                    No students found.
                  </td>
                </tr>
              ) : (
                students.map((student: any) => (
                  <tr key={student.id} className="bg-white dark:bg-slate-950 hover:bg-slate-50 dark:hover:bg-slate-900/50 transition-colors">
                    <td className="px-6 py-4">
                      <div className="flex items-center gap-3">
                        <div className="w-8 h-8 rounded-full bg-slate-100 dark:bg-slate-800 flex items-center justify-center text-slate-600 dark:text-slate-300 font-medium">
                          {student.first_name?.[0] || 'U'}
                        </div>
                        <div>
                          <div className="font-medium text-slate-900 dark:text-white">
                            {student.first_name || 'Unknown'} {student.last_name || 'Student'}
                          </div>
                          <div className="text-xs text-slate-500">
                            ID: {student.id.substring(0, 8)}...
                          </div>
                        </div>
                      </div>
                    </td>
                    <td className="px-6 py-4 text-slate-600 dark:text-slate-300">
                      {student.email}
                    </td>
                    <td className="px-6 py-4">
                      {student.enrollments?.[0] ? (
                        <div className="flex flex-col">
                          <span className="inline-flex w-fit items-center px-2 py-1 rounded-md bg-indigo-50 dark:bg-indigo-900/30 text-indigo-700 dark:text-indigo-300 text-xs font-bold border border-indigo-100 dark:border-indigo-800">
                            {student.enrollments[0].classes?.name} (Sem {student.enrollments[0].classes?.semester})
                          </span>
                          <span className="text-xs text-slate-500 mt-1 font-mono">
                            Roll: {student.enrollments[0].roll_number}
                          </span>
                        </div>
                      ) : (
                        <span className="inline-flex items-center px-2 py-1 rounded-md bg-slate-100 dark:bg-slate-800 text-slate-600 dark:text-slate-300 text-xs font-medium">
                          {student.departments?.name || 'Unassigned'}
                        </span>
                      )}
                    </td>
                    <td className="px-6 py-4 text-slate-500">
                      {new Date(student.created_at).toLocaleDateString()}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </Card>
    </div>
  )
}
