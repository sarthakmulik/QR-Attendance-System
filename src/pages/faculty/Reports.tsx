import { useState } from 'react'
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Download, AlertTriangle, FileSpreadsheet, Loader2, Users, CheckCircle2 } from 'lucide-react'
import { useLowAttendanceReport } from '@/hooks/queries'

export default function Reports() {
  const [threshold, setThreshold] = useState('75')
  const { data: defaulters, isLoading } = useLowAttendanceReport(parseInt(threshold))

  const handleExport = () => {
    // Simulated export
    alert(`Exporting ${defaulters?.length || 0} records to CSV...`)
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
              <Button variant="outline" className="w-full justify-start text-slate-600 font-normal">
                Department-wise Summary
              </Button>
              <Button variant="outline" className="w-full justify-start text-slate-600 font-normal">
                Subject-wise Summary
              </Button>
              <Button variant="outline" className="w-full justify-start text-slate-600 font-normal">
                Monthly Attendance Log
              </Button>
            </CardContent>
          </Card>
        </div>
      </div>
    </div>
  )
}
