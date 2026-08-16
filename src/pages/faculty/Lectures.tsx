import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Play, Clock, Calendar as CalendarIcon, Loader2, Users, PlusCircle, Radio } from 'lucide-react'
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { useAuth } from '@/context/AuthContext'
import { useTimetable, useClasses, useSubjects, useActiveSessions } from '@/hooks/queries'
import { useMutation } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'

export default function Lectures() {
  const { user } = useAuth()
  const navigate = useNavigate()
  
  const [activeTab, setActiveTab] = useState<'my' | 'dept' | 'adhoc'>('my')
  const [selectedClassId, setSelectedClassId] = useState('')
  const [selectedSubjectId, setSelectedSubjectId] = useState('')
  const [sessionDuration, setSessionDuration] = useState(60) // default 1 hour

  const { data: timetable, isLoading: isLoadingTimetable } = useTimetable()
  const { data: classes, isLoading: isLoadingClasses } = useClasses()
  const { data: subjects, isLoading: isLoadingSubjects } = useSubjects()
  const { data: activeSessions } = useActiveSessions()

  const myActiveSessions = activeSessions?.filter((s: any) => s.faculty_id === user?.id) || []

  const today = new Date().getDay()
  const activeDay = today === 0 ? 7 : today

  const myLectures = timetable?.filter((t: any) => t.faculty_id === user?.id && t.day_of_week === activeDay) || []
  const otherLectures = timetable?.filter((t: any) => t.faculty_id !== user?.id && t.day_of_week === activeDay) || []

  const startSessionMutation = useMutation({
    mutationFn: async (payload: { timetableId?: string, classId?: string, subjectId?: string, duration: number }) => {
      const expiresAt = new Date(Date.now() + payload.duration * 60000).toISOString()

      const { data, error } = await supabase
        .from('attendance_sessions')
        .insert({
          timetable_id: payload.timetableId || null,
          class_id: payload.classId || null,
          subject_id: payload.subjectId || null,
          faculty_id: user?.id,
          expires_at: expiresAt,
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

  const handleStartAdHoc = () => {
    if (!selectedClassId || !selectedSubjectId) {
      toast.error("Please select both a Class and a Subject.")
      return
    }
    startSessionMutation.mutate({ classId: selectedClassId, subjectId: selectedSubjectId, duration: sessionDuration })
  }

  // Helper to render lecture cards
  const renderLectures = (lectures: any[], emptyMessage: string) => {
    if (isLoadingTimetable) {
      return (
        <div className="flex flex-col items-center justify-center h-48 text-slate-500">
          <Loader2 className="w-8 h-8 animate-spin mb-4 text-primary" />
          Loading schedule...
        </div>
      )
    }

    if (lectures.length === 0) {
      return (
        <div className="flex flex-col items-center justify-center h-64 text-center border border-dashed border-slate-200 rounded-xl bg-slate-50/50">
          <div className="bg-slate-100 p-4 rounded-full mb-4">
            <CalendarIcon className="w-8 h-8 text-slate-400" />
          </div>
          <h3 className="text-lg font-semibold text-slate-900">{emptyMessage}</h3>
        </div>
      )
    }

    return (
      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        {lectures.map((lecture: any) => (
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
                  Scheduled for: {lecture.users?.first_name} {lecture.users?.last_name}
                </div>
              </div>
              
              <Button 
                onClick={() => startSessionMutation.mutate({ timetableId: lecture.id, duration: sessionDuration })}
                disabled={startSessionMutation.isPending}
                className="gap-2 bg-green-600 hover:bg-green-700"
              >
                {startSessionMutation.isPending && startSessionMutation.variables?.timetableId === lecture.id ? (
                  <Loader2 size={16} className="animate-spin" />
                ) : (
                  <Play size={16} />
                )}
                Take Class
              </Button>
            </CardContent>
          </Card>
        ))}
      </div>
    )
  }

  return (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-slate-900 dark:text-white tracking-tight">Live Lectures Hub</h1>
          <p className="text-slate-500 text-sm mt-1">Start a scheduled class, substitute for another teacher, or launch an extra lecture.</p>
        </div>
        
        <div className="bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-800 rounded-lg p-3 flex items-center gap-3 shadow-sm">
          <Clock size={16} className="text-primary" />
          <div className="flex flex-col">
            <span className="text-xs font-semibold text-slate-500 uppercase">Auto-End Session In</span>
            <select 
              className="bg-transparent text-sm font-medium focus:outline-none cursor-pointer"
              value={sessionDuration}
              onChange={(e) => setSessionDuration(Number(e.target.value))}
            >
              <option value={30}>30 Minutes</option>
              <option value={45}>45 Minutes</option>
              <option value={60}>1 Hour</option>
              <option value={90}>1.5 Hours</option>
              <option value={120}>2 Hours</option>
            </select>
          </div>
        </div>
      </div>

      {/* Ongoing Sessions Banner */}
      {myActiveSessions.length > 0 && (
        <div className="bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-xl p-4">
          <div className="flex items-center gap-2 text-blue-700 dark:text-blue-400 font-semibold mb-3">
            <Radio className="animate-pulse" size={18} />
            Ongoing Lectures
          </div>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            {myActiveSessions.map((session: any) => {
              const subjectName = session.timetable?.subjects?.name || session.subjects?.name || 'Ad-Hoc Session'
              const className = session.timetable?.classes?.name || session.classes?.name || 'Unknown Class'
              
              return (
                <div key={session.id} className="bg-white dark:bg-slate-900 p-3 rounded-lg border border-blue-100 shadow-sm flex items-center justify-between">
                  <div>
                    <p className="font-medium text-slate-900 dark:text-white">{subjectName}</p>
                    <p className="text-xs text-slate-500">{className}</p>
                  </div>
                  <Button 
                    size="sm" 
                    onClick={() => navigate(`/faculty/live-session/${session.id}`)}
                    className="bg-blue-600 hover:bg-blue-700"
                  >
                    Resume
                  </Button>
                </div>
              )
            })}
          </div>
        </div>
      )}

      {/* Custom Tabs */}
      <div className="flex space-x-2 border-b border-slate-200">
        <button
          onClick={() => setActiveTab('my')}
          className={`pb-3 px-4 text-sm font-medium transition-colors border-b-2 ${activeTab === 'my' ? 'border-primary text-primary' : 'border-transparent text-slate-500 hover:text-slate-700 hover:border-slate-300'}`}
        >
          My Schedule
        </button>
        <button
          onClick={() => setActiveTab('dept')}
          className={`pb-3 px-4 text-sm font-medium transition-colors border-b-2 ${activeTab === 'dept' ? 'border-primary text-primary' : 'border-transparent text-slate-500 hover:text-slate-700 hover:border-slate-300'}`}
        >
          Substitute Lectures
        </button>
        <button
          onClick={() => setActiveTab('adhoc')}
          className={`pb-3 px-4 text-sm font-medium transition-colors border-b-2 ${activeTab === 'adhoc' ? 'border-primary text-primary' : 'border-transparent text-slate-500 hover:text-slate-700 hover:border-slate-300'}`}
        >
          Ad-Hoc / Extra Lecture
        </button>
      </div>

      {/* Tab Content */}
      <div className="mt-6">
        {activeTab === 'my' && renderLectures(myLectures, 'You have no lectures scheduled for today.')}
        {activeTab === 'dept' && renderLectures(otherLectures, 'No other lectures scheduled in the department today.')}
        
        {activeTab === 'adhoc' && (
          <Card className="border-none shadow-sm max-w-2xl">
            <CardHeader>
              <CardTitle>Start an Extra Lecture</CardTitle>
              <CardDescription>Launch a live QR attendance session for an unscheduled class.</CardDescription>
            </CardHeader>
            <CardContent className="space-y-4">
              <div className="space-y-2">
                <label className="text-sm font-medium text-slate-700">Target Class</label>
                <select 
                  className="w-full p-2 border border-slate-200 rounded-md focus:outline-none focus:ring-2 focus:ring-primary/50"
                  value={selectedClassId}
                  onChange={e => setSelectedClassId(e.target.value)}
                >
                  <option value="">Select a class...</option>
                  {classes?.map((c: any) => (
                    <option key={c.id} value={c.id}>{c.name}</option>
                  ))}
                </select>
                <p className="text-xs text-slate-500">The GPS geofence will be locked to this classroom's physical location.</p>
              </div>

              <div className="space-y-2">
                <label className="text-sm font-medium text-slate-700">Subject Taught</label>
                <select 
                  className="w-full p-2 border border-slate-200 rounded-md focus:outline-none focus:ring-2 focus:ring-primary/50"
                  value={selectedSubjectId}
                  onChange={e => setSelectedSubjectId(e.target.value)}
                >
                  <option value="">Select a subject...</option>
                  {subjects?.map((s: any) => (
                    <option key={s.id} value={s.id}>{s.name} ({s.code})</option>
                  ))}
                </select>
              </div>

              <Button 
                onClick={handleStartAdHoc}
                disabled={startSessionMutation.isPending}
                className="w-full gap-2 mt-4 bg-primary hover:bg-primary/90"
              >
                {startSessionMutation.isPending && !startSessionMutation.variables?.timetableId ? (
                  <Loader2 size={16} className="animate-spin" />
                ) : (
                  <Play size={16} />
                )}
                Start Live Session Now
              </Button>
            </CardContent>
          </Card>
        )}
      </div>
    </div>
  )
}
