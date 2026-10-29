import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card'
import { CheckCircle, XCircle, Loader2, BookOpen, Clock } from 'lucide-react'
import { useAuth } from '@/context/AuthContext'
import { useStudentStats, useSubjectStats } from '@/hooks/queries'

export default function StudentDashboard() {
  const { user } = useAuth()
  
  // Custom hook to fetch all attendance records for this student across all sessions?
  // We can fetch from `attendance_records` directly where student_id = user.id
  
  const { data: overallStats, isLoading: overallLoading } = useStudentStats(user?.id)
  const { data: subjectStats, isLoading: subjectLoading } = useSubjectStats(user?.id)

  const percentage = overallStats?.attendance_percentage || 0
  const isHealthy = percentage >= 75

  return (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div>
        <h1 className="text-2xl font-bold text-slate-900 dark:text-white tracking-tight">Student Dashboard</h1>
        <p className="text-slate-500 text-sm mt-1">Welcome back, {user?.user_metadata?.first_name || 'Student'}!</p>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
        <Card className="border-none shadow-sm relative overflow-hidden">
          <div className={`absolute top-0 right-0 w-24 h-24 -mr-8 -mt-8 rounded-full opacity-10 ${isHealthy ? 'bg-green-500' : 'bg-red-500'}`}></div>
          <CardContent className="p-6">
            <p className="text-sm font-medium text-slate-500 mb-1">Overall Attendance</p>
            <div className="flex items-end gap-2">
              <h3 className={`text-4xl font-bold ${isHealthy ? 'text-green-600' : 'text-red-600'}`}>
                {overallLoading ? <Loader2 className="animate-spin w-8 h-8 mt-1" /> : `${percentage}%`}
              </h3>
            </div>
            {!overallLoading && (
              <p className="text-xs text-slate-400 mt-2">
                {isHealthy ? 'Keep it up! You are above 75%.' : 'Warning: Your attendance is below 75%.'}
              </p>
            )}
          </CardContent>
        </Card>

        <Card className="border-none shadow-sm">
          <CardContent className="p-6 flex items-center gap-4">
            <div className="p-4 rounded-2xl bg-blue-100 text-blue-600">
              <CheckCircle size={24} />
            </div>
            <div>
              <p className="text-sm font-medium text-slate-500">Classes Attended</p>
              <h3 className="text-2xl font-bold text-slate-900">
                {overallLoading ? <Loader2 className="animate-spin w-5 h-5 mt-1" /> : overallStats?.attended_sessions || 0}
              </h3>
            </div>
          </CardContent>
        </Card>

        <Card className="border-none shadow-sm">
          <CardContent className="p-6 flex items-center gap-4">
            <div className="p-4 rounded-2xl bg-amber-100 text-amber-600">
              <XCircle size={24} />
            </div>
            <div>
              <p className="text-sm font-medium text-slate-500">Missed Classes</p>
              <h3 className="text-2xl font-bold text-slate-900">
                {overallLoading ? <Loader2 className="animate-spin w-5 h-5 mt-1" /> : (overallStats?.total_sessions || 0) - (overallStats?.attended_sessions || 0)}
              </h3>
            </div>
          </CardContent>
        </Card>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <Card className="border-none shadow-sm">
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <BookOpen size={18} className="text-primary" />
              Subject Breakdown
            </CardTitle>
            <CardDescription>Your attendance percentage per subject.</CardDescription>
          </CardHeader>
          <CardContent>
            {subjectLoading ? (
              <div className="flex justify-center py-8"><Loader2 className="animate-spin text-primary" /></div>
            ) : !subjectStats || subjectStats.length === 0 ? (
              <div className="text-center py-8 text-slate-500 text-sm bg-slate-50 rounded-lg">
                No subjects found. Wait for lectures to be held.
              </div>
            ) : (
              <div className="space-y-4">
                {subjectStats.map((sub: any) => (
                  <div key={sub.subject_id} className="space-y-2">
                    <div className="flex justify-between text-sm">
                      <span className="font-medium text-slate-700">{sub.subject_name}</span>
                      <span className={sub.attendance_percentage >= 75 ? 'text-green-600 font-bold' : 'text-red-600 font-bold'}>
                        {sub.attendance_percentage}%
                      </span>
                    </div>
                    <div className="h-2 w-full bg-slate-100 rounded-full overflow-hidden">
                      <div 
                        className={`h-full ${sub.attendance_percentage >= 75 ? 'bg-green-500' : 'bg-red-500'}`}
                        style={{ width: `${Math.min(sub.attendance_percentage, 100)}%` }}
                      ></div>
                    </div>
                    <p className="text-xs text-slate-400 text-right">
                      {sub.attended_sessions} / {sub.total_sessions} attended
                    </p>
                  </div>
                ))}
              </div>
            )}
          </CardContent>
        </Card>

        <Card className="border-none shadow-sm">
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Clock size={18} className="text-primary" />
              Recent Activity
            </CardTitle>
            <CardDescription>Your latest successful scans.</CardDescription>
          </CardHeader>
          <CardContent>
             <div className="text-center py-12 text-slate-500 text-sm bg-slate-50 rounded-lg">
                Your recent attendance history will appear here.
             </div>
          </CardContent>
        </Card>
      </div>
    </div>
  )
}
