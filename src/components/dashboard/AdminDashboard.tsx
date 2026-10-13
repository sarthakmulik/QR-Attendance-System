import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Users, BookOpen, CheckCircle, AlertTriangle, Loader2, ArrowRight } from 'lucide-react'
import { useDashboardStats, useGlobalRecentScans, useLowAttendanceReport } from '@/hooks/queries'

export default function AdminDashboard() {
  const { data: statsData, isLoading: statsLoading } = useDashboardStats()
  const { data: recentScans, isLoading: scansLoading } = useGlobalRecentScans()
  const { data: defaulters, isLoading: defaultersLoading } = useLowAttendanceReport(75)

  const stats = [
    { title: "Total Students", value: statsData?.totalStudents ?? statsData?.total_students ?? 0, icon: Users, color: "text-blue-600", bg: "bg-blue-100" },
    { title: "Active Classes", value: statsData?.activeClasses ?? statsData?.active_classes ?? 0, icon: BookOpen, color: "text-indigo-600", bg: "bg-indigo-100" },
    { title: "Today's Attendance", value: `${statsData?.todayAttendancePct ?? statsData?.today_attendance_pct ?? 0}%`, icon: CheckCircle, color: "text-emerald-600", bg: "bg-emerald-100" },
    { title: "At Risk (<75%)", value: statsData?.lowAttendanceCount ?? statsData?.low_attendance_count ?? 0, icon: AlertTriangle, color: "text-rose-600", bg: "bg-rose-100" }
  ]

  return (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div>
        <h1 className="text-2xl font-bold text-slate-900 dark:text-white tracking-tight">Overview Dashboard</h1>
        <p className="text-slate-500 text-sm mt-1">Real-time metrics for your department's attendance.</p>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
        {stats.map((stat, i) => {
          const Icon = stat.icon
          return (
            <Card key={i} className="border-none shadow-sm hover:shadow-md transition-shadow">
              <CardContent className="p-6 flex items-center gap-4">
                <div className={`p-4 rounded-2xl ${stat.bg} ${stat.color}`}>
                  <Icon size={24} />
                </div>
                <div>
                  <p className="text-sm font-medium text-slate-500">{stat.title}</p>
                  <h3 className="text-2xl font-bold text-slate-900">
                    {statsLoading ? <Loader2 className="w-5 h-5 animate-spin mt-1 text-slate-400" /> : stat.value}
                  </h3>
                </div>
              </CardContent>
            </Card>
          )
        })}
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <Card className="lg:col-span-2 border-none shadow-sm flex flex-col">
          <CardHeader>
            <CardTitle>Defaulters Watchlist</CardTitle>
            <CardDescription>Top students falling below the 75% attendance threshold.</CardDescription>
          </CardHeader>
          <CardContent className="flex-1">
            {defaultersLoading ? (
              <div className="flex h-[200px] items-center justify-center">
                <Loader2 className="w-8 h-8 animate-spin text-slate-400" />
              </div>
            ) : !defaulters || defaulters.length === 0 ? (
              <div className="flex h-[200px] flex-col items-center justify-center text-center text-slate-500 bg-slate-50/50 rounded-lg border border-dashed border-slate-200">
                <CheckCircle className="w-8 h-8 text-emerald-400 mb-2" />
                <p>No students at risk! Everyone is above 75%.</p>
              </div>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-sm text-left">
                  <thead className="text-xs text-slate-500 uppercase bg-slate-50 dark:bg-slate-900/50">
                    <tr>
                      <th className="px-4 py-3 font-semibold rounded-tl-lg">Student Name</th>
                      <th className="px-4 py-3 font-semibold text-right rounded-tr-lg">Overall %</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100 dark:divide-slate-800">
                    {defaulters.map((d: any) => (
                      <tr key={d.student_id} className="hover:bg-slate-50 dark:hover:bg-slate-900/50">
                        <td className="px-4 py-3 font-medium text-slate-900 dark:text-slate-100">
                          {d.first_name || d.users?.first_name} {d.last_name || d.users?.last_name}
                        </td>
                        <td className="px-4 py-3 text-right">
                          <span className="px-2.5 py-1 rounded-full text-xs font-medium bg-rose-100 text-rose-700">
                            {d.attendance_percentage}%
                          </span>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
                <div className="mt-4 text-center">
                  <a href="/faculty/reports" className="text-sm text-primary hover:underline font-medium inline-flex items-center">
                    View Full Report <ArrowRight size={14} className="ml-1" />
                  </a>
                </div>
              </div>
            )}
          </CardContent>
        </Card>
        
        <Card className="border-none shadow-sm flex flex-col">
          <CardHeader>
            <CardTitle>Live Scans</CardTitle>
            <CardDescription>Real-time feed across campus</CardDescription>
          </CardHeader>
          <CardContent className="flex-1">
            {scansLoading ? (
              <div className="flex h-[200px] items-center justify-center">
                <Loader2 className="w-8 h-8 animate-spin text-slate-400" />
              </div>
            ) : !recentScans || recentScans.length === 0 ? (
              <div className="flex h-[200px] flex-col items-center justify-center text-center text-slate-500 bg-slate-50/50 rounded-lg border border-dashed border-slate-200">
                <p className="text-sm">No recent scans.</p>
              </div>
            ) : (
              <div className="space-y-4">
                {recentScans.map((scan: any) => (
                  <div key={scan.id} className="flex items-center justify-between border-b border-slate-100 dark:border-slate-800 pb-3 last:border-0 last:pb-0">
                    <div>
                      <p className="text-sm font-medium text-slate-900 dark:text-slate-100">{scan.student_name}</p>
                      <p className="text-xs text-slate-500">{scan.subject_name}</p>
                    </div>
                    <div className="text-right">
                      <span className="px-2 py-0.5 rounded text-[10px] font-bold uppercase tracking-wider bg-emerald-100 text-emerald-700">
                        {scan.status}
                      </span>
                      <p className="text-[10px] text-slate-400 mt-1">
                        {new Date(scan.scanned_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                      </p>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  )
}
