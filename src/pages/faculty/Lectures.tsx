import { useNavigate } from 'react-router-dom'
import { Play, Clock, Calendar as CalendarIcon, Loader2 } from 'lucide-react'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { useAuth } from '@/context/AuthContext'
import { useTimetable } from '@/hooks/queries'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'

export default function Lectures() {
  const { user } = useAuth()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  
  const { data: timetable, isLoading } = useTimetable()

  // Find today's day of week (1 = Monday, ..., 7 = Sunday)
  const today = new Date().getDay()
  const activeDay = today === 0 ? 7 : today

  // Filter lectures for the logged-in faculty and today
  const myLectures = timetable?.filter((t: any) => t.faculty_id === user?.id && t.day_of_week === activeDay) || []

  const startSessionMutation = useMutation({
    mutationFn: async (timetableId: string) => {
      const token = Math.random().toString(36).substring(2, 10).toUpperCase()
      const expiresAt = new Date(Date.now() + 15000).toISOString() // 15 seconds

      const { data, error } = await supabase
        .from('attendance_sessions')
        .insert({
          timetable_id: timetableId,
          faculty_id: user?.id,
          current_token: token,
          token_expires_at: expiresAt,
          is_active: true
        })
        .select()
        .single()

      if (error) throw error
      return data
    },
    onSuccess: (data) => {
      toast.success('Lecture session started!')
      navigate(`/faculty/live-session/${data.id}`)
    },
    onError: (error: any) => {
      toast.error(error.message || 'Failed to start session')
    }
  })

  return (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div>
        <h1 className="text-2xl font-bold text-slate-900 dark:text-white tracking-tight">My Lectures Today</h1>
        <p className="text-slate-500 text-sm mt-1">Start a live attendance session for your scheduled classes.</p>
      </div>

      {isLoading ? (
        <div className="flex flex-col items-center justify-center h-48 text-slate-500">
          <Loader2 className="w-8 h-8 animate-spin mb-4 text-primary" />
          Loading your schedule...
        </div>
      ) : myLectures.length === 0 ? (
        <div className="flex flex-col items-center justify-center h-64 text-center border border-dashed border-slate-200 rounded-xl bg-slate-50/50">
          <div className="bg-slate-100 p-4 rounded-full mb-4">
            <CalendarIcon className="w-8 h-8 text-slate-400" />
          </div>
          <h3 className="text-lg font-semibold text-slate-900">No lectures scheduled today</h3>
          <p className="text-slate-500 max-w-sm mt-1">Enjoy your free time or check the master timetable for other days.</p>
        </div>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
          {myLectures.map((lecture: any) => (
            <Card key={lecture.id} className="border-none shadow-sm hover:shadow-md transition-shadow">
              <CardHeader className="pb-3 border-b border-slate-100">
                <div className="flex justify-between items-start">
                  <div>
                    <CardTitle className="text-xl text-primary">{lecture.subjects?.name}</CardTitle>
                    <p className="text-sm font-mono text-slate-500 mt-1">{lecture.subjects?.code}</p>
                  </div>
                  <span className="bg-slate-100 text-slate-700 text-xs font-semibold px-2.5 py-1 rounded-md">
                    {lecture.classes?.name}
                  </span>
                </div>
              </CardHeader>
              <CardContent className="pt-4 flex items-center justify-between">
                <div className="space-y-1">
                  <div className="flex items-center gap-2 text-sm text-slate-600">
                    <Clock size={16} className="text-slate-400" />
                    <span className="font-medium">{lecture.start_time.substring(0, 5)} - {lecture.end_time.substring(0, 5)}</span>
                  </div>
                  <div className="text-sm text-slate-500 pl-6">
                    Room {lecture.room_number || 'TBA'}
                  </div>
                </div>
                
                <Button 
                  onClick={() => startSessionMutation.mutate(lecture.id)}
                  disabled={startSessionMutation.isPending}
                  className="gap-2 bg-green-600 hover:bg-green-700"
                >
                  {startSessionMutation.isPending && startSessionMutation.variables === lecture.id ? (
                    <Loader2 size={16} className="animate-spin" />
                  ) : (
                    <Play size={16} />
                  )}
                  Start Lecture
                </Button>
              </CardContent>
            </Card>
          ))}
        </div>
      )}
    </div>
  )
}
