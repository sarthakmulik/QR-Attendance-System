import { useState, useMemo } from 'react'
import { Plus, MoreVertical, BookOpen, Loader2 } from 'lucide-react'
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
import { useSubjects, useDepartments } from '@/hooks/queries'
import { useAuth } from '@/context/AuthContext'
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuTrigger } from '@/components/ui/dropdown-menu'

const subjectSchema = z.object({
  department_id: z.string().optional(),
  code: z.string().min(2, 'Subject code is required'),
  name: z.string().min(2, 'Subject name is required'),
  credits: z.coerce.number().min(1).max(10),
  semester: z.coerce.number().min(1).max(10),
})

type SubjectFormValues = z.infer<typeof subjectSchema>

export default function Subjects() {
  const { userRole, userDepartmentId } = useAuth()
  const [isDialogOpen, setIsDialogOpen] = useState(false)
  const queryClient = useQueryClient()
  const { data: subjects, isLoading } = useSubjects()
  const { data: departments } = useDepartments()

  const visibleSubjects = useMemo(() => {
    if (!subjects) return []
    if (userRole === 'hod' && userDepartmentId) {
      return subjects.filter((s: any) => s.department_id === userDepartmentId)
    }
    return subjects
  }, [subjects, userRole, userDepartmentId])

  const form = useForm<SubjectFormValues>({
    resolver: zodResolver(subjectSchema),
    defaultValues: {
      department_id: '',
      code: '',
      name: '',
      credits: 3,
      semester: 1,
    },
  })

  const createSubjectMutation = useMutation({
    mutationFn: async (values: SubjectFormValues) => {
      const { data, error } = await supabase
        .from('subjects')
        .insert({
          department_id: userRole === 'hod' ? userDepartmentId : values.department_id,
          code: values.code,
          name: values.name,
          credits: values.credits,
          semester: values.semester,
        })
        .select()
        .single()
      
      if (error) throw error
      return data
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['subjects'] })
      toast.success('Subject created successfully')
      setIsDialogOpen(false)
      form.reset()
    },
    onError: (error: any) => {
      toast.error(error.message || 'Failed to create subject')
    },
  })

  const deleteSubjectMutation = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('subjects').delete().eq('id', id)
      if (error) throw error
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['subjects'] })
      toast.success('Subject deleted successfully')
    },
    onError: (error: any) => {
      toast.error(error.message || 'Failed to delete subject')
    }
  })

  const onSubmit = (values: SubjectFormValues) => {
    createSubjectMutation.mutate(values)
  }

  return (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-slate-900 dark:text-white tracking-tight">Subjects</h1>
          <p className="text-slate-500 text-sm mt-1">Manage the course catalog and academic subjects.</p>
        </div>
        
        <Dialog open={isDialogOpen} onOpenChange={setIsDialogOpen}>
          <DialogTrigger asChild>
            <Button className="gap-2 shadow-sm">
              <Plus size={16} />
              Add Subject
            </Button>
          </DialogTrigger>
          <DialogContent className="sm:max-w-[425px]">
            <form onSubmit={form.handleSubmit(onSubmit)}>
              <DialogHeader>
                <DialogTitle>Add New Subject</DialogTitle>
                <DialogDescription>
                  Define a new subject for a specific department.
                </DialogDescription>
              </DialogHeader>
              <div className="grid gap-4 py-4 max-h-[60vh] overflow-y-auto px-1">
                {userRole !== 'hod' && (
                  <div className="space-y-2">
                    <Label htmlFor="department_id">Department *</Label>
                    <Controller
                      control={form.control}
                      name="department_id"
                      render={({ field }) => (
                        <Select onValueChange={field.onChange} defaultValue={field.value}>
                          <SelectTrigger>
                            <SelectValue placeholder="Select a department" />
                          </SelectTrigger>
                          <SelectContent>
                            {departments?.map((dept: any) => (
                              <SelectItem key={dept.id} value={dept.id}>
                                {dept.name}
                              </SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                      )}
                    />
                    {form.formState.errors.department_id && (
                      <p className="text-xs text-destructive">{form.formState.errors.department_id.message}</p>
                    )}
                  </div>
                )}
                <div className="grid grid-cols-2 gap-4">
                  <div className="space-y-2">
                    <Label htmlFor="code">Subject Code *</Label>
                    <Input id="code" placeholder="e.g. CS101" className="uppercase" {...form.register('code')} />
                    {form.formState.errors.code && (
                      <p className="text-xs text-destructive">{form.formState.errors.code.message}</p>
                    )}
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="name">Subject Name *</Label>
                    <Input id="name" placeholder="e.g. Data Structures" {...form.register('name')} />
                    {form.formState.errors.name && (
                      <p className="text-xs text-destructive">{form.formState.errors.name.message}</p>
                    )}
                  </div>
                </div>
                <div className="grid grid-cols-2 gap-4">
                  <div className="space-y-2">
                    <Label htmlFor="credits">Credits</Label>
                    <Input id="credits" type="number" min="1" max="10" {...form.register('credits')} />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="semester">Semester</Label>
                    <Input id="semester" type="number" min="1" max="10" {...form.register('semester')} />
                  </div>
                </div>
              </div>
              <DialogFooter>
                <Button type="button" variant="outline" onClick={() => setIsDialogOpen(false)}>Cancel</Button>
                <Button type="submit" disabled={createSubjectMutation.isPending}>
                  {createSubjectMutation.isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                  Save Subject
                </Button>
              </DialogFooter>
            </form>
          </DialogContent>
        </Dialog>
      </div>

      <Card className="border-none shadow-sm overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm text-left">
            <thead className="text-xs text-slate-500 uppercase bg-slate-50/50 dark:bg-slate-900/50 border-b border-slate-200 dark:border-slate-800">
              <tr>
                <th className="px-6 py-4 font-semibold">Subject Code</th>
                <th className="px-6 py-4 font-semibold">Name</th>
                <th className="px-6 py-4 font-semibold">Department</th>
                <th className="px-6 py-4 font-semibold">Semester</th>
                <th className="px-6 py-4 font-semibold text-center">Credits</th>
                <th className="px-6 py-4 text-right font-semibold">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100 dark:divide-slate-800 bg-white dark:bg-slate-950">
              {isLoading ? (
                <tr>
                  <td colSpan={6} className="px-6 py-8 text-center text-slate-500">
                    <Loader2 className="w-6 h-6 animate-spin mx-auto mb-2 text-primary" />
                    Loading subjects...
                  </td>
                </tr>
              ) : !visibleSubjects || visibleSubjects.length === 0 ? (
                <tr>
                  <td colSpan={6} className="px-6 py-12 text-center">
                    <div className="flex flex-col items-center justify-center">
                      <div className="bg-slate-100 dark:bg-slate-900 p-4 rounded-full mb-4">
                        <BookOpen className="w-8 h-8 text-slate-400" />
                      </div>
                      <h3 className="text-lg font-semibold text-slate-900 dark:text-white">No subjects found</h3>
                      <p className="text-slate-500 max-w-sm mt-1">Add your first subject to the catalog.</p>
                    </div>
                  </td>
                </tr>
              ) : (
                visibleSubjects.map((subject: any) => (
                  <tr key={subject.id} className="hover:bg-slate-50 dark:hover:bg-slate-900/50 transition-colors">
                    <td className="px-6 py-4">
                      <span className="bg-slate-100 dark:bg-slate-800 px-2 py-1 rounded text-xs font-mono font-medium text-slate-700 dark:text-slate-300">
                        {subject.code}
                      </span>
                    </td>
                    <td className="px-6 py-4 font-medium text-slate-900 dark:text-slate-100">
                      {subject.name}
                    </td>
                    <td className="px-6 py-4 text-slate-600 dark:text-slate-400">
                      {subject.departments?.name || '—'}
                    </td>
                    <td className="px-6 py-4 text-slate-600 dark:text-slate-400">
                      Sem {subject.semester}
                    </td>
                    <td className="px-6 py-4 text-center text-slate-600 dark:text-slate-400">
                      {subject.credits}
                    </td>
                    <td className="px-6 py-4 text-right">
                      <DropdownMenu>
                        <DropdownMenuTrigger asChild>
                          <Button variant="ghost" size="icon" className="text-slate-400 hover:text-slate-600">
                            <MoreVertical size={16} />
                          </Button>
                        </DropdownMenuTrigger>
                        <DropdownMenuContent align="end" className="w-48">
                          <DropdownMenuLabel>Actions</DropdownMenuLabel>
                          <DropdownMenuSeparator />
                          <DropdownMenuItem 
                            onClick={() => deleteSubjectMutation.mutate(subject.id)}
                            className="text-rose-600 focus:text-rose-600 focus:bg-rose-50"
                          >
                            Delete Subject
                          </DropdownMenuItem>
                        </DropdownMenuContent>
                      </DropdownMenu>
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
