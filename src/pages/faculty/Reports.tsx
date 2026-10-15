import { useState } from 'react'
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Download, AlertTriangle, FileSpreadsheet, Loader2, Users, CheckCircle2, UserX, Building2, BookOpen, CalendarDays, AlertCircle } from 'lucide-react'
import {
  useLowAttendanceReport,
  useFacultyAudit,
  useDepartmentSummary,
  useSubjectSummary,
  useMonthlyLog,
} from '@/hooks/queries'
import { useAuth } from '@/context/AuthContext'
import { toast } from 'sonner'

type QuickReportType = 'department' | 'subject' | 'monthly'

const QUICK_REPORTS: { id: QuickReportType; label: string; icon: typeof Building2 }[] = [
  { id: 'department', label: 'Department-wise Summary', icon: Building2 },
  { id: 'subject', label: 'Subject-wise Summary', icon: BookOpen },
  { id: 'monthly', label: 'Monthly Attendance Log', icon: CalendarDays },
]

// Local-time ISO date (YYYY-MM-DD). toISOString() would shift back a day for
// anyone east of UTC, which silently truncates the reporting range.
const toISO = (d: Date) => {
  const y = d.getFullYear()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${y}-${m}-${day}`
}
const defaultFromISO = () => {
  const d = new Date()
  d.setMonth(d.getMonth() - 6)
  return toISO(d)
}

export default function Reports() {
  const { userRole } = useAuth()
  const [activeTab, setActiveTab] = useState<'students' | 'faculty'>('students')
  const [threshold, setThreshold] = useState('75')

  // Quick Reports (was: three dead placeholder buttons).
  const [quickReport, setQuickReport] = useState<QuickReportType | null>(null)
  const [rangeFrom, setRangeFrom] = useState<string>(defaultFromISO)
  const [rangeTo, setRangeTo] = useState<string>(() => toISO(new Date()))

  const { data: defaulters, isLoading } = useLowAttendanceReport(parseInt(threshold))
  const { data: facultyAudit, isLoading: isLoadingAudit } = useFacultyAudit()

  // Only the open report fetches; the others stay idle.
  const range = quickReport ? { from: rangeFrom, to: rangeTo } : null
  const deptQuery = useDepartmentSummary(quickReport === 'department' ? range : null)
  const subjectQuery = useSubjectSummary(quickReport === 'subject' ? range : null)
  const monthlyQuery = useMonthlyLog(quickReport === 'monthly' ? range : null)

  const activeQuery =
    quickReport === 'department' ? deptQuery
    : quickReport === 'subject' ? subjectQuery
    : quickReport === 'monthly' ? monthlyQuery
    : null

  const canViewFacultyAudit = ['super_admin', 'principal', 'hod'].includes(userRole || '')

  // Escape a value for safe CSV output: quotes doubled, and formula-triggering
  // leading characters (=, +, -, @, tab, CR) prefixed with an apostrophe to
  // prevent spreadsheet formula injection.
  const csvCell = (value: unknown): string => {
    let s = value == null ? '' : String(value)
    if (/^[=+\-@\t\r]/.test(s)) {
      s = `'${s}`
    }
    return `"${s.replace(/"/g, '""')}"`
  }

  const downloadCsv = (headers: string, rows: string[], filename: string) => {
    const blob = new Blob([headers + rows.join('\n')], { type: 'text/csv;charset=utf-8;' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = filename
    a.click()
    URL.revokeObjectURL(url)
  }

  const pctColor = (p: number) =>
    p < 50 ? 'bg-red-100 text-red-700' : p < 75 ? 'bg-orange-100 text-orange-700' : 'bg-green-100 text-green-700'

  const handleQuickReportExport = () => {
    const rows: any[] = activeQuery?.data || []
    if (!quickReport || rows.length === 0) {
      toast.info('No records to export.')
      return
    }
    const suffix = `${rangeFrom}_to_${rangeTo}`
    if (quickReport === 'department') {
      const headers = 'Department,Students,Lectures Held,Attended,Expected,Attendance %,Avg Student %\n'
      downloadCsv(
        headers,
        rows.map((r) =>
          `${csvCell(r.department_name)},${r.students},${r.lectures_held},${r.attendances},${r.expected},${r.attendance_pct}%,${r.avg_student_pct}%`
        ),
        `department_summary_${suffix}.csv`
      )
    } else if (quickReport === 'subject') {
      const headers = 'Subject Code,Subject Name,Department,Students,Lectures Held,Attended,Expected,Attendance %,Avg Student %\n'
      downloadCsv(
        headers,
        rows.map((r) =>
          `${csvCell(r.subject_code)},${csvCell(r.subject_name)},${csvCell(r.department_name)},${r.students},${r.lectures_held},${r.attendances},${r.expected},${r.attendance_pct}%,${r.avg_student_pct}%`
        ),
        `subject_summary_${suffix}.csv`
      )
    } else {
      const headers = 'Month,Students,Lectures Held,Attended,Expected,Attendance %,Avg Student %\n'
      downloadCsv(
        headers,
        rows.map((r) =>
          `${csvCell(r.month_label)},${r.students},${r.lectures_held},${r.attendances},${r.expected},${r.attendance_pct}%,${r.avg_student_pct}%`
        ),
        `monthly_attendance_log_${suffix}.csv`
      )
    }
    toast.success('Report exported successfully!')
  }

  const handleExport = () => {
    if (activeTab === 'students' && quickReport) {
      handleQuickReportExport()
      return
    }
    if (activeTab === 'students') {
      if (!defaulters || defaulters.length === 0) {
        toast.info("No defaulter records to export.")
        return
      }
      const headers = "Student Name,Email,Classes Attended,Classes Held,Attendance Percentage\n"
      const rows = defaulters.map((s: any) => 
        `${csvCell(`${s.first_name} ${s.last_name}`)},${csvCell(s.email)},${s.attended_sessions || 0},${s.total_sessions || 0},${s.attendance_percentage}%`
      )
      downloadCsv(headers, rows, `student_defaulters_${threshold}pct_${new Date().toISOString().split('T')[0]}.csv`)
      toast.success("Student defaulters report exported successfully!")
    } else {
      if (!facultyAudit || facultyAudit.length === 0) {
        toast.info("No faculty audit records to export.")
        return
      }
      const headers = "Date,Faculty Name,Subject,Class,Time,Status\n"
      const rows = facultyAudit.map((a: any) => 
        `${csvCell(new Date(a.lecture_date).toLocaleDateString())},${csvCell(`${a.first_name} ${a.last_name}`)},${csvCell(a.subject_name)},${csvCell(a.class_name)},${csvCell(`${a.start_time?.substring(0,5)} - ${a.end_time?.substring(0,5)}`)},${csvCell(a.status)}`
      )
      downloadCsv(headers, rows, `faculty_audit_30d_${new Date().toISOString().split('T')[0]}.csv`)
      toast.success("Faculty compliance report exported successfully!")
    }
  }

  return (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-slate-900 dark:text-white tracking-tight">Attendance Reports</h1>
          <p className="text-slate-500 text-sm mt-1">Identify students at risk and export attendance data.</p>
        </div>
        <Button onClick={handleExport} className="gap-2 bg-slate-900 text-white shadow-sm hover:bg-slate-800">
          <Download size={16} />
          Export CSV
        </Button>
      </div>

      {canViewFacultyAudit && (
        <div className="flex space-x-2 border-b border-slate-200 mb-6">
          <button
            onClick={() => setActiveTab('students')}
            className={`pb-3 px-4 text-sm font-medium transition-colors border-b-2 ${activeTab === 'students' ? 'border-primary text-primary' : 'border-transparent text-slate-500 hover:text-slate-700 hover:border-slate-300'}`}
          >
            Student Defaulters
          </button>
          <button
            onClick={() => setActiveTab('faculty')}
            className={`pb-3 px-4 text-sm font-medium transition-colors border-b-2 ${activeTab === 'faculty' ? 'border-primary text-primary' : 'border-transparent text-slate-500 hover:text-slate-700 hover:border-slate-300'}`}
          >
            Faculty Compliance Audit
          </button>
        </div>
      )}

      {activeTab === 'students' && quickReport && (
        <Card className="border-none shadow-sm">
          <CardHeader className="flex flex-row flex-wrap items-center justify-between gap-4 border-b border-slate-100 pb-4">
            <div>
              <CardTitle className="text-lg flex items-center gap-2">
                <FileSpreadsheet size={18} className="text-indigo-500" />
                {QUICK_REPORTS.find((r) => r.id === quickReport)?.label}
              </CardTitle>
              <CardDescription>
                {quickReport === 'monthly'
                  ? 'Lectures conducted and attendance recorded in each month.'
                  : 'Aggregate lecture history for the selected date range.'}
              </CardDescription>
            </div>
            <div className="flex flex-wrap items-end gap-2">
              <div>
                <span className="text-xs text-slate-500 block mb-1">From</span>
                <Input
                  type="date"
                  value={rangeFrom}
                  max={rangeTo}
                  onChange={(e) => setRangeFrom(e.target.value || defaultFromISO())}
                  className="h-9 w-[150px]"
                />
              </div>
              <div>
                <span className="text-xs text-slate-500 block mb-1">To</span>
                <Input
                  type="date"
                  value={rangeTo}
                  min={rangeFrom}
                  onChange={(e) => setRangeTo(e.target.value || toISO(new Date()))}
                  className="h-9 w-[150px]"
                />
              </div>
              <Button variant="outline" size="sm" className="h-9" onClick={() => setQuickReport(null)}>
                Close
              </Button>
            </div>
          </CardHeader>
          <CardContent className="pt-4">
            <div className="flex flex-wrap gap-2 mb-4">
              {QUICK_REPORTS.map((r) => {
                const Icon = r.icon
                const isActive = quickReport === r.id
                return (
                  <button
                    key={r.id}
                    onClick={() => setQuickReport(r.id)}
                    className={`inline-flex items-center gap-1.5 rounded-full px-3 py-1.5 text-xs font-semibold transition-colors ${
                      isActive ? 'bg-slate-900 text-white' : 'bg-slate-100 text-slate-600 hover:bg-slate-200'
                    }`}
                  >
                    <Icon size={13} />
                    {r.label}
                  </button>
                )
              })}
            </div>

            <div className="overflow-x-auto">
              <table className="w-full text-sm text-left">
                <thead className="text-xs text-slate-500 uppercase bg-slate-50/50">
                  <tr>
                    {quickReport === 'department' && <th className="px-6 py-4 font-semibold">Department</th>}
                    {quickReport === 'subject' && <th className="px-6 py-4 font-semibold">Subject</th>}
                    {quickReport === 'subject' && <th className="px-6 py-4 font-semibold">Department</th>}
                    {quickReport === 'monthly' && <th className="px-6 py-4 font-semibold">Month</th>}
                    <th className="px-6 py-4 font-semibold text-center">Students</th>
                    <th className="px-6 py-4 font-semibold text-center">Lectures Held</th>
                    <th className="px-6 py-4 font-semibold text-center">Attended / Expected</th>
                    <th className="px-6 py-4 font-semibold text-right">Attendance %</th>
                    <th className="px-6 py-4 font-semibold text-right">Avg Student %</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {activeQuery?.isLoading ? (
                    <tr>
                      <td colSpan={7} className="px-6 py-12 text-center text-slate-500">
                        <Loader2 className="w-8 h-8 animate-spin mx-auto mb-2 text-primary" />
                        Building report...
                      </td>
                    </tr>
                  ) : activeQuery?.isError ? (
                    <tr>
                      <td colSpan={7} className="px-6 py-12 text-center text-slate-500">
                        <div className="bg-red-50 w-12 h-12 rounded-full flex items-center justify-center mx-auto mb-3 text-red-600">
                          <AlertCircle size={24} />
                        </div>
                        <p className="font-medium text-slate-900">Could not load this report</p>
                        <p className="text-xs mt-1">{(activeQuery.error as Error)?.message}</p>
                      </td>
                    </tr>
                  ) : !activeQuery?.data || activeQuery.data.length === 0 ? (
                    <tr>
                      <td colSpan={7} className="px-6 py-12 text-center text-slate-500">
                        <div className="bg-green-50 w-12 h-12 rounded-full flex items-center justify-center mx-auto mb-3 text-green-600">
                          <CheckCircle2 size={24} />
                        </div>
                        <p className="font-medium text-slate-900">Nothing to report</p>
                        <p>No lectures were recorded between {rangeFrom} and {rangeTo}.</p>
                      </td>
                    </tr>
                  ) : (
                    activeQuery.data.map((row: any, i: number) => (
                      <tr key={row.department_id || row.subject_id || row.month_start || i} className="hover:bg-slate-50">
                        {quickReport === 'department' && (
                          <td className="px-6 py-4 font-medium text-slate-900">{row.department_name}</td>
                        )}
                        {quickReport === 'subject' && (
                          <td className="px-6 py-4">
                            <div className="text-slate-900 font-medium">{row.subject_name}</div>
                            <div className="text-xs text-slate-500">{row.subject_code}</div>
                          </td>
                        )}
                        {quickReport === 'subject' && (
                          <td className="px-6 py-4 text-slate-600">{row.department_name}</td>
                        )}
                        {quickReport === 'monthly' && (
                          <td className="px-6 py-4 font-medium text-slate-900">{row.month_label}</td>
                        )}
                        <td className="px-6 py-4 text-center text-slate-600 font-medium">{row.students}</td>
                        <td className="px-6 py-4 text-center text-slate-600 font-medium">{row.lectures_held}</td>
                        <td className="px-6 py-4 text-center text-slate-600">
                          <span className="font-medium">{row.attendances}</span>
                          <span className="text-slate-400"> / {row.expected}</span>
                        </td>
                        <td className="px-6 py-4 text-right">
                          <span className={`inline-flex items-center justify-center px-2.5 py-1 rounded-full text-xs font-bold ${pctColor(Number(row.attendance_pct))}`}>
                            {row.attendance_pct}%
                          </span>
                        </td>
                        <td className="px-6 py-4 text-right">
                          <span className={`inline-flex items-center justify-center px-2.5 py-1 rounded-full text-xs font-bold ${pctColor(Number(row.avg_student_pct))}`}>
                            {row.avg_student_pct}%
                          </span>
                        </td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </div>
          </CardContent>
        </Card>
      )}

      {activeTab === 'students' && !quickReport && (
        <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
          <Card className="border-none shadow-sm md:col-span-2">
            <CardHeader className="flex flex-row items-center justify-between border-b border-slate-100 pb-4">
              <div>
                <CardTitle className="text-lg flex items-center gap-2">
                  <AlertTriangle size={18} className="text-red-500" />
                  Defaulters List
                </CardTitle>
                <CardDescription>Students with attendance below the required threshold.</CardDescription>
              </div>
              <div className="w-40">
                <Select value={threshold} onValueChange={setThreshold}>
                  <SelectTrigger>
                    <SelectValue placeholder="Threshold" />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="85">Below 85%</SelectItem>
                    <SelectItem value="75">Below 75%</SelectItem>
                    <SelectItem value="60">Below 60%</SelectItem>
                    <SelectItem value="50">Below 50%</SelectItem>
                  </SelectContent>
                </Select>
              </div>
            </CardHeader>
            <CardContent className="p-0">
              <div className="overflow-x-auto">
                <table className="w-full text-sm text-left">
                  <thead className="text-xs text-slate-500 uppercase bg-slate-50/50">
                    <tr>
                      <th className="px-6 py-4 font-semibold">Student Name</th>
                      <th className="px-6 py-4 font-semibold text-center">Classes Attended</th>
                      <th className="px-6 py-4 font-semibold text-center">Classes Held</th>
                      <th className="px-6 py-4 font-semibold text-right">Attendance %</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {isLoading ? (
                      <tr>
                        <td colSpan={4} className="px-6 py-12 text-center text-slate-500">
                          <Loader2 className="w-8 h-8 animate-spin mx-auto mb-2 text-primary" />
                          Generating report...
                        </td>
                      </tr>
                    ) : !defaulters || defaulters.length === 0 ? (
                      <tr>
                        <td colSpan={4} className="px-6 py-12 text-center text-slate-500">
                          <div className="bg-green-50 w-12 h-12 rounded-full flex items-center justify-center mx-auto mb-3 text-green-600">
                            <CheckCircle2 size={24} />
                          </div>
                          <p className="font-medium text-slate-900">All good!</p>
                          <p>No students fall below the {threshold}% threshold.</p>
                        </td>
                      </tr>
                    ) : (
                      defaulters.map((student: any) => (
                        <tr key={student.student_id} className="hover:bg-slate-50">
                          <td className="px-6 py-4">
                            <div className="font-medium text-slate-900">{student.first_name} {student.last_name}</div>
                            <div className="text-xs text-slate-500">{student.email}</div>
                          </td>
                          <td className="px-6 py-4 text-center text-slate-600 font-medium">
                            {student.attended_sessions}
                          </td>
                          <td className="px-6 py-4 text-center text-slate-600 font-medium">
                            {student.total_sessions}
                          </td>
                          <td className="px-6 py-4 text-right">
                            <span className={`inline-flex items-center justify-center px-2.5 py-1 rounded-full text-xs font-bold ${
                              student.attendance_percentage < 50 ? 'bg-red-100 text-red-700' : 'bg-orange-100 text-orange-700'
                            }`}>
                              {student.attendance_percentage}%
                            </span>
                          </td>
                        </tr>
                      ))
                    )}
                  </tbody>
                </table>
              </div>
            </CardContent>
          </Card>

          <div className="space-y-6">
            <Card className="border-none shadow-sm bg-primary text-white">
              <CardContent className="p-6">
                <div className="flex items-center gap-4">
                  <div className="p-3 bg-white/20 rounded-xl">
                    <Users size={24} />
                  </div>
                  <div>
                    <p className="text-primary-foreground/80 text-sm font-medium">At Risk Students</p>
                    <h3 className="text-3xl font-bold mt-1">{defaulters?.length || 0}</h3>
                  </div>
                </div>
              </CardContent>
            </Card>

            <Card className="border-none shadow-sm">
              <CardHeader>
                <CardTitle className="text-base flex items-center gap-2">
                  <FileSpreadsheet size={18} className="text-indigo-500" />
                  Quick Reports
                </CardTitle>
              </CardHeader>
              <CardContent className="space-y-2">
                {QUICK_REPORTS.map((r) => {
                  const Icon = r.icon
                  const isActive = quickReport === r.id
                  return (
                    <Button
                      key={r.id}
                      variant="outline"
                      onClick={() => setQuickReport(isActive ? null : r.id)}
                      className={`w-full justify-start font-normal gap-2 ${
                        isActive ? 'border-primary bg-primary/5 text-primary' : 'text-slate-600'
                      }`}
                    >
                      <Icon size={15} />
                      {r.label}
                    </Button>
                  )
                })}
              </CardContent>
            </Card>
          </div>
        </div>
      )}

      {activeTab === 'faculty' && canViewFacultyAudit && (
        <Card className="border-none shadow-sm">
          <CardHeader className="flex flex-row items-center justify-between border-b border-slate-100 pb-4">
            <div>
              <CardTitle className="text-lg flex items-center gap-2">
                <UserX size={18} className="text-red-500" />
                Faculty Missed Lectures (30 Days)
              </CardTitle>
              <CardDescription>Audit report of faculty who missed scheduled lectures.</CardDescription>
            </div>
          </CardHeader>
          <CardContent className="p-0">
            <div className="overflow-x-auto">
              <table className="w-full text-sm text-left">
                <thead className="text-xs text-slate-500 uppercase bg-slate-50/50">
                  <tr>
                    <th className="px-6 py-4 font-semibold">Date</th>
                    <th className="px-6 py-4 font-semibold">Faculty</th>
                    <th className="px-6 py-4 font-semibold">Subject / Class</th>
                    <th className="px-6 py-4 font-semibold">Time</th>
                    <th className="px-6 py-4 font-semibold text-right">Status</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {isLoadingAudit ? (
                    <tr>
                      <td colSpan={5} className="px-6 py-12 text-center text-slate-500">
                        <Loader2 className="w-8 h-8 animate-spin mx-auto mb-2 text-primary" />
                        Analyzing timetables...
                      </td>
                    </tr>
                  ) : !facultyAudit || facultyAudit.length === 0 ? (
                    <tr>
                      <td colSpan={5} className="px-6 py-12 text-center text-slate-500">
                        <div className="bg-green-50 w-12 h-12 rounded-full flex items-center justify-center mx-auto mb-3 text-green-600">
                          <CheckCircle2 size={24} />
                        </div>
                        <p className="font-medium text-slate-900">100% Compliance!</p>
                        <p>No faculty missed a lecture in the past 30 days.</p>
                      </td>
                    </tr>
                  ) : (
                    facultyAudit.map((audit: any, index: number) => (
                      <tr key={`${audit.timetable_id}-${audit.lecture_date}-${index}`} className="hover:bg-slate-50">
                        <td className="px-6 py-4 font-medium text-slate-900">
                          {new Date(audit.lecture_date).toLocaleDateString()}
                        </td>
                        <td className="px-6 py-4">
                          <div className="font-medium text-slate-900">{audit.first_name} {audit.last_name}</div>
                        </td>
                        <td className="px-6 py-4">
                          <div className="text-slate-900 font-medium">{audit.subject_name}</div>
                          <div className="text-xs text-slate-500">{audit.class_name} (Sem {audit.semester})</div>
                        </td>
                        <td className="px-6 py-4 text-slate-600 font-medium">
                          {audit.start_time.substring(0,5)} - {audit.end_time.substring(0,5)}
                        </td>
                        <td className="px-6 py-4 text-right">
                          {audit.status === 'Absent' ? (
                            <span className="inline-flex items-center justify-center px-2.5 py-1 rounded-md text-xs font-bold bg-red-100 text-red-700">
                              Missed Lecture
                            </span>
                          ) : (
                            <span className="inline-flex items-center justify-center px-2.5 py-1 rounded-md text-xs font-bold bg-green-100 text-green-700">
                              Conducted
                            </span>
                          )}
                        </td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </div>
          </CardContent>
        </Card>
      )}
    </div>
  )
}
