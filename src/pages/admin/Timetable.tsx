import { useState } from 'react'
import { Plus, Calendar as CalendarIcon, Clock, Loader2 } from 'lucide-react'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
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
import { useTimetable, useClasses, useSubjects, useUsers } from '@/hooks/queries'
import { useAuth } from '@/context/AuthContext'
import { useMemo } from 'react'

const lectureSchema = z.object({
  class_id: z.string().min(1, 'Please select a class'),
  subject_id: z.string().min(1, 'Please select a subject'),
  faculty_id: z.string().min(1, 'Please select a faculty member'),
  day_of_week: z.coerce.number().min(1).max(7),
  start_time: z.string().regex(/^([01]\d|2[0-3]):([0-5]\d)$/, 'Invalid time format (HH:MM)'),
  end_time: z.string().regex(/^([01]\d|2[0-3]):([0-5]\d)$/, 'Invalid time format (HH:MM)'),
  room_number: z.string().optional(),
})

type LectureFormValues = z.infer<typeof lectureSchema>

const DAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']

export default function Timetable() {
  const [isDialogOpen, setIsDialogOpen] = useState(false)
  const [activeDay, setActiveDay] = useState(1) // 1 = Monday
  const queryClient = useQueryClient()
  
  const { data: entries, isLoading } = useTimetable()
  const { data: classes } = useClasses()
  const { data: subjects } = useSubjects()
  const { data: users } = useUsers()
  const { user, userRole, userDepartmentId } = useAuth()
  
  // Filter classes for Class Teacher or HOD
  const filteredClasses = useMemo(() => {
    if (!classes) return []
    if (userRole === 'class_teacher') {
      return classes.filter((c: any) => c.class_teacher_id === user?.id)
    }
    if (userRole === 'hod' && userDepartmentId) {
      return classes.filter((c: any) => c.department_id === userDepartmentId)
    }
    return classes
  }, [classes, userRole, user, userDepartmentId])

  // Filter subjects for HOD
  const filteredSubjects = useMemo(() => {
    if (!subjects) return []
    if (userRole === 'hod' && userDepartmentId) {
      return subjects.filter((s: any) => s.department_id === userDepartmentId)
    }
    return subjects
  }, [subjects, userRole, userDepartmentId])

  // Filter for faculty users
  const facultyUsers = useMemo(() => {
    if (!users) return []
    const faculty = users.filter((u: any) => u.role === 'faculty' || u.role === 'hod' || u.role === 'class_teacher')
    if (userRole === 'hod' && userDepartmentId) {
      return faculty.filter((u: any) => u.department_id === userDepartmentId)
    }
    return faculty
  }, [users, userRole, userDepartmentId])

  const form = useForm<LectureFormValues>({
    resolver: zodResolver(lectureSchema),
    defaultValues: {
      class_id: '',
      subject_id: '',
      faculty_id: '',
      day_of_week: 1,
      start_time: '09:00',
      end_time: '10:00',
      room_number: '',
    },
  })

  const createLectureMutation = useMutation({
    mutationFn: async (values: LectureFormValues) => {
      const { data, error } = await supabase
        .from('timetable')
        .insert({
          class_id: values.class_id,
          subject_id: values.subject_id,
          faculty_id: values.faculty_id,
          day_of_week: values.day_of_week,
          start_time: values.start_time,
          end_time: values.end_time,
          room_number: values.room_number || null,
        })
        .select()
        .single()
      
      if (error) throw error
      return data
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['timetable'] })
      toast.success('Lecture scheduled successfully')
      setIsDialogOpen(false)
      form.reset()
    },
    onError: (error: any) => {
      toast.error(error.message || 'Failed to schedule lecture')
    },
  })

  const onSubmit = (values: LectureFormValues) => {
    createLectureMutation.mutate(values)
  }

  const dailyEntries = entries?.filter((e: any) => e.day_of_week === activeDay) || []

  return (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-slate-900 dark:text-white tracking-tight">Master Timetable</h1>
          <p className="text-slate-500 text-sm mt-1">Schedule and manage lectures across all departments.</p>
        </div>
        
        <Dialog open={isDialogOpen} onOpenChange={setIsDialogOpen}>
          <DialogTrigger asChild>
            <Button className="gap-2 shadow-sm">
              <Plus size={16} />
              Add Lecture
            </Button>
          </DialogTrigger>
          <DialogContent className="sm:max-w-[500px]">
            <form onSubmit={form.handleSubmit(onSubmit)}>
              <DialogHeader>
                <DialogTitle>Schedule New Lecture</DialogTitle>
                <DialogDescription>
                  Allocate a time slot for a subject and assign a faculty member.
                </DialogDescription>
              </DialogHeader>
              <div className="grid gap-4 py-4 max-h-[60vh] overflow-y-auto px-1">
                <div className="grid grid-cols-2 gap-4">
                  <div className="space-y-2">
                    <Label htmlFor="class_id">Class / Division *</Label>
                    <Controller
                      control={form.control}
                      name="class_id"
                      render={({ field }) => (
                        <Select onValueChange={field.onChange} defaultValue={field.value}>
                          <SelectTrigger>
                            <SelectValue placeholder="Select class" />
                          </SelectTrigger>
                          <SelectContent>
                            {filteredClasses?.map((cls: any) => (
                              <SelectItem key={cls.id} value={cls.id}>{cls.name} (Sem {cls.semester})</SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                      )}
                    />
                    {filteredClasses?.length === 0 && (
                      <p className="text-xs text-orange-500 mt-1">
                        {userRole === 'class_teacher' 
                          ? "You are not assigned as a Class Teacher." 
                          : "No classes available."}
                      </p>
                    )}
                    {form.formState.errors.class_id && (
                      <p className="text-xs text-destructive">{form.formState.errors.class_id.message}</p>
                    )}
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="subject_id">Subject *</Label>
                    <Controller
                      control={form.control}
                      name="subject_id"
                      render={({ field }) => (
                        <Select onValueChange={field.onChange} defaultValue={field.value}>
                          <SelectTrigger>
                            <SelectValue placeholder="Select subject" />
                          </SelectTrigger>
                          <SelectContent>
                            {filteredSubjects?.map((sub: any) => (
                              <SelectItem key={sub.id} value={sub.id}>{sub.name}</SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                      )}
                    />
                    {form.formState.errors.subject_id && (
                      <p className="text-xs text-destructive">{form.formState.errors.subject_id.message}</p>
                    )}
                  </div>
                </div>
                
                <div className="space-y-2">
                  <Label htmlFor="faculty_id">Assign Faculty *</Label>
                  <Controller
                    control={form.control}
                    name="faculty_id"
                    render={({ field }) => (
                      <Select onValueChange={field.onChange} defaultValue={field.value}>
                        <SelectTrigger>
                          <SelectValue placeholder="Select faculty" />
                        </SelectTrigger>
                        <SelectContent>
                          {facultyUsers.map((fac: any) => (
                            <SelectItem key={fac.id} value={fac.id}>{fac.first_name} {fac.last_name}</SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                    )}
                  />
                  {form.formState.errors.faculty_id && (
                    <p className="text-xs text-destructive">{form.formState.errors.faculty_id.message}</p>
                  )}
                </div>

                <div className="space-y-2">
                  <Label htmlFor="day_of_week">Day of the Week</Label>
                  <Controller
                    control={form.control}
                    name="day_of_week"
                    render={({ field }) => (
                      <Select onValueChange={(v) => field.onChange(parseInt(v))} defaultValue={field.value.toString()}>
                        <SelectTrigger>
                          <SelectValue placeholder="Select day" />
                        </SelectTrigger>
                        <SelectContent>
                          {DAYS.map((day, idx) => (
                            <SelectItem key={day} value={(idx + 1).toString()}>{day}</SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                    )}
                  />
                </div>

                <div className="grid grid-cols-2 gap-4">
                  <div className="space-y-2">
                    <Label htmlFor="start_time">Start Time (HH:MM)</Label>
                    <Input id="start_time" type="time" {...form.register('start_time')} />
                    {form.formState.errors.start_time && (
                      <p className="text-xs text-destructive">{form.formState.errors.start_time.message}</p>
                    )}
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="end_time">End Time (HH:MM)</Label>
                    <Input id="end_time" type="time" {...form.register('end_time')} />
                    {form.formState.errors.end_time && (
                      <p className="text-xs text-destructive">{form.formState.errors.end_time.message}</p>
                    )}
                  </div>
                </div>

                <div className="space-y-2">
                  <Label htmlFor="room_number">Room Number (Optional)</Label>
                  <Input id="room_number" placeholder="e.g. 402-A" {...form.register('room_number')} />
                </div>
              </div>
              <DialogFooter>
                <Button type="button" variant="outline" onClick={() => setIsDialogOpen(false)}>Cancel</Button>
                <Button type="submit" disabled={createLectureMutation.isPending}>
                  {createLectureMutation.isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                  Save Lecture
                </Button>
              </DialogFooter>
            </form>
          </DialogContent>
        </Dialog>
      </div>

      <div className="flex gap-2 overflow-x-auto pb-2">
        {DAYS.map((day, idx) => (
          <Button
            key={day}
            variant={activeDay === idx + 1 ? "default" : "outline"}
            className="rounded-full"
            onClick={() => setActiveDay(idx + 1)}
          >
            {day}
          </Button>
        ))}
      </div>

      <Card className="border-none shadow-sm min-h-[400px] bg-slate-50/50 dark:bg-slate-900/20">
        <CardContent className="p-6">
          {isLoading ? (
            <div className="flex flex-col items-center justify-center h-48 text-slate-500">
              <Loader2 className="w-8 h-8 animate-spin mb-4 text-primary" />
              Loading schedule...
            </div>
          ) : dailyEntries.length === 0 ? (
            <div className="flex flex-col items-center justify-center h-64 text-center">
              <div className="bg-slate-100 dark:bg-slate-900 p-4 rounded-full mb-4">
                <CalendarIcon className="w-8 h-8 text-slate-400" />
              </div>
              <h3 className="text-lg font-semibold text-slate-900 dark:text-white">No lectures scheduled</h3>
              <p className="text-slate-500 max-w-sm mt-1">There are no lectures scheduled for {DAYS[activeDay-1]}.</p>
            </div>
          ) : (
            <div className="space-y-4 relative before:absolute before:inset-y-0 before:left-[118px] before:w-[2px] before:bg-slate-200 dark:before:bg-slate-800">
              {dailyEntries.map((entry: any) => (
                <div key={entry.id} className="relative flex items-start gap-8">
                  <div className="w-20 pt-3 text-right">
                    <span className="text-sm font-semibold text-slate-900 dark:text-white">{entry.start_time.substring(0, 5)}</span>
                  </div>
                  <div className="absolute left-[111px] top-4 w-4 h-4 rounded-full bg-white border-[3px] border-primary z-10 dark:bg-slate-950"></div>
                  <Card className="flex-1 border-none shadow-sm hover:shadow-md transition-shadow">
                    <CardHeader className="p-4 pb-2 flex flex-row items-start justify-between space-y-0">
                      <div>
                        <CardTitle className="text-base text-primary">{entry.subjects?.name}</CardTitle>
                        <p className="text-sm text-slate-500 font-mono mt-1">{entry.subjects?.code}</p>
                      </div>
                      <span className="bg-slate-100 dark:bg-slate-800 text-slate-600 dark:text-slate-300 text-xs font-medium px-2.5 py-1 rounded-md">
                        {entry.classes?.name}
                      </span>
                    </CardHeader>
                    <CardContent className="p-4 pt-0 flex items-center justify-between">
                      <div className="flex items-center gap-2 text-sm text-slate-600 dark:text-slate-400">
                        <div className="w-6 h-6 rounded-full bg-slate-200 dark:bg-slate-800 flex items-center justify-center text-[10px] font-bold uppercase">
                          {entry.users?.first_name?.[0]}{entry.users?.last_name?.[0]}
                        </div>
                        {entry.users?.first_name} {entry.users?.last_name}
                      </div>
                      <div className="flex items-center gap-4 text-xs font-medium text-slate-500">
                        <div className="flex items-center gap-1">
                          <Clock size={14} />
                          {entry.start_time.substring(0, 5)} - {entry.end_time.substring(0, 5)}
                        </div>
                        <div className="px-2 py-1 bg-slate-50 dark:bg-slate-800 border border-slate-200 dark:border-slate-700 rounded text-slate-600 dark:text-slate-300">
                          Room: {entry.room_number || 'TBD'}
                        </div>
                      </div>
                    </CardContent>
                  </Card>
                </div>
              ))}
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  )
}
