import { useMemo } from 'react'
import { Accordion, AccordionContent, AccordionItem, AccordionTrigger } from '@/components/ui/accordion'
import { Card } from '@/components/ui/card'
import { UsersIcon, UserIcon, GraduationCapIcon, BookOpenIcon, MoreVertical } from 'lucide-react'
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuTrigger } from '@/components/ui/dropdown-menu'
import { Button } from '@/components/ui/button'

type UserTreeViewProps = {
  hierarchy: any
  userRole: string | null
  onEditRole: (user: any) => void
}

export function UserTreeView({ hierarchy, userRole, onEditRole }: UserTreeViewProps) {
  const { users, classes, enrollments, timetable } = hierarchy

  const tree = useMemo(() => {
    // 1. Organize users by role
    const hods = users.filter((u: any) => u.role === 'hod')
    const classTeachers = users.filter((u: any) => u.role === 'class_teacher')
    const faculties = users.filter((u: any) => u.role === 'faculty')
    const students = users.filter((u: any) => u.role === 'student')

    // 2. Link Students to Classes
    const studentsByClass = new Map()
    const assignedStudentIds = new Set()
    enrollments.forEach((enrollment: any) => {
      const student = students.find((s: any) => s.id === enrollment.student_id)
      if (student) {
        // ENHANCEMENT: Attach enrollment data to student so it can be edited
        student.class_id = enrollment.class_id
        student.roll_number = enrollment.roll_number

        assignedStudentIds.add(student.id)
        if (!studentsByClass.has(enrollment.class_id)) studentsByClass.set(enrollment.class_id, [])
        studentsByClass.get(enrollment.class_id).push(student)
      }
    })

    // 3. Link Classes to Class Teachers
    const classTeachersWithStudents = classTeachers.map((ct: any) => {
      const assignedClasses = classes.filter((c: any) => c.class_teacher_id === ct.id)
      const myStudents = assignedClasses.flatMap((c: any) => studentsByClass.get(c.id) || [])
      return { ...ct, class_id: assignedClasses[0]?.id, assignedClasses, students: myStudents }
    })

    // 4. Link Faculties to Students (via Timetable -> Class)
    const facultiesWithStudents = faculties.map((f: any) => {
      const myTimetables = timetable.filter((t: any) => t.faculty_id === f.id)
      const classIds = [...new Set(myTimetables.map((t: any) => t.class_id))]
      const myStudents = classIds.flatMap((cid: any) => studentsByClass.get(cid) || [])
      // Remove duplicates
      const uniqueStudents = Array.from(new Map(myStudents.map((s: any) => [s.id, s])).values())
      return { ...f, students: uniqueStudents }
    })

    // 5. Group by Department (for HODs)
    const groupedByDept = new Map()
    const allStaff = [...classTeachersWithStudents, ...facultiesWithStudents]
    
    allStaff.forEach(staff => {
      const deptId = staff.department_id || 'unassigned'
      if (!groupedByDept.has(deptId)) groupedByDept.set(deptId, [])
      groupedByDept.get(deptId).push(staff)
    })

    const hodsWithStaff = hods.map((hod: any) => {
      return {
        ...hod,
        staff: groupedByDept.get(hod.department_id) || []
      }
    })

    // Find Unassigned Students (not in any class)
    const unassignedStudents = students.filter((s: any) => !assignedStudentIds.has(s.id))

    // Find Unassigned Staff (no department)
    const unassignedStaff = groupedByDept.get('unassigned') || []

    return { hodsWithStaff, allStaff, classTeachersWithStudents, unassignedStudents, unassignedStaff }
  }, [hierarchy])

  // Helpers to render User Row
  const renderUserRow = (user: any, indent: number = 0, extraInfo?: string) => (
    <div className={`flex items-center justify-between p-3 hover:bg-slate-50 dark:hover:bg-slate-900/50 rounded-lg transition-colors ml-${indent}`}>
      <div className="flex items-center gap-3">
        <div className="w-9 h-9 rounded-full bg-slate-200 dark:bg-slate-800 flex items-center justify-center text-slate-600 dark:text-slate-300 shrink-0">
          {user.first_name?.[0] || 'U'}{user.last_name?.[0] || 'N'}
        </div>
        <div>
          <p className="font-medium text-slate-900 dark:text-slate-100 flex items-center gap-2">
            {user.first_name || 'Unknown'} {user.last_name || 'User'}
            <span className="text-[10px] uppercase font-bold tracking-wider px-2 py-0.5 rounded-full bg-slate-100 dark:bg-slate-800 text-slate-500">
              {user.role.replace('_', ' ')}
            </span>
          </p>
          <p className="text-xs text-slate-500">{user.email} {extraInfo && `• ${extraInfo}`}</p>
        </div>
      </div>
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button variant="ghost" size="icon" className="text-slate-400 hover:text-slate-600">
            <MoreVertical size={16} />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end">
          <DropdownMenuLabel>Actions</DropdownMenuLabel>
          <DropdownMenuSeparator />
          <DropdownMenuItem onClick={() => onEditRole(user)}>
            Edit Role & Department
          </DropdownMenuItem>
          {user.role === 'student' && (
            <DropdownMenuItem>View Progress & Attendance</DropdownMenuItem>
          )}
        </DropdownMenuContent>
      </DropdownMenu>
    </div>
  )

  const renderStaffNode = (staff: any) => (
    <AccordionItem value={staff.id} key={staff.id} className="border-none px-4">
      <div className="flex items-center justify-between group">
        <AccordionTrigger className="hover:no-underline py-2 flex-1">
          <div className="flex items-center gap-2 text-left">
            {staff.role === 'class_teacher' ? <BookOpenIcon size={16} className="text-amber-500" /> : <UserIcon size={16} className="text-emerald-500" />}
            <span>{staff.first_name || 'Unknown'} {staff.last_name || 'User'}</span>
            <span className="text-xs text-slate-400 font-normal ml-2">({staff.students?.length || 0} Students)</span>
          </div>
        </AccordionTrigger>
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button variant="ghost" size="icon" className="text-slate-400 hover:text-slate-600 opacity-0 group-hover:opacity-100 transition-opacity">
              <MoreVertical size={16} />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem onClick={() => onEditRole(staff)}>
              Edit Role & Department
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
      <AccordionContent className="pb-4 pt-1">
        <div className="pl-6 border-l-2 border-slate-100 dark:border-slate-800 space-y-1">
          {staff.students?.map((student: any) => renderUserRow(student))}
          {(!staff.students || staff.students.length === 0) && (
            <div className="p-4 text-sm text-slate-400 text-center bg-slate-50 dark:bg-slate-900/50 rounded-lg">No students assigned.</div>
          )}
        </div>
      </AccordionContent>
    </AccordionItem>
  )

  return (
    <Card className="border-none shadow-sm overflow-hidden">
      <Accordion type="multiple" className="w-full">
        {/* Principal View (Sees HODs) */}
        {(userRole === 'super_admin' || userRole === 'principal') && tree.hodsWithStaff.map((hod: any) => (
          <AccordionItem value={hod.id} key={hod.id} className="border-b border-slate-100 dark:border-slate-800">
            <div className="flex items-center justify-between group px-6 bg-slate-50/50 dark:bg-slate-900/50">
              <AccordionTrigger className="hover:no-underline flex-1 py-4">
                <div className="flex items-center gap-3 text-left">
                  <UsersIcon size={18} className="text-indigo-500" />
                  <div>
                    <div className="font-semibold">{hod.first_name || 'Unknown'} {hod.last_name || 'User'}</div>
                    <div className="text-xs font-normal text-slate-500">HOD • {hod.department_name || 'No Dept'}</div>
                  </div>
                </div>
              </AccordionTrigger>
              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <Button variant="ghost" size="icon" className="text-slate-400 hover:text-slate-600 opacity-0 group-hover:opacity-100 transition-opacity">
                    <MoreVertical size={16} />
                  </Button>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end">
                  <DropdownMenuItem onClick={() => onEditRole(hod)}>
                    Edit Role & Department
                  </DropdownMenuItem>
                </DropdownMenuContent>
              </DropdownMenu>
            </div>
            <AccordionContent className="p-0">
              <div className="bg-white dark:bg-slate-950 p-4">
                <Accordion type="multiple" className="w-full border border-slate-100 dark:border-slate-800 rounded-lg">
                  {hod.staff.map(renderStaffNode)}
                  {hod.staff.length === 0 && (
                    <div className="p-8 text-center text-slate-400 text-sm">No Faculty or Class Teachers under this HOD.</div>
                  )}
                </Accordion>
              </div>
            </AccordionContent>
          </AccordionItem>
        ))}

        {/* HOD View (Sees Faculty directly) */}
        {userRole === 'hod' && (
          <div className="p-4 bg-white dark:bg-slate-950">
            <Accordion type="multiple" className="w-full border border-slate-100 dark:border-slate-800 rounded-lg">
              {tree.allStaff.map(renderStaffNode)}
              {tree.allStaff.length === 0 && (
                <div className="p-8 text-center text-slate-400 text-sm">No Faculty or Class Teachers in your department.</div>
              )}
            </Accordion>
          </div>
        )}

        {/* Class Teacher View (Sees Students directly) */}
        {userRole === 'class_teacher' && (
          <div className="p-4 space-y-1 bg-white dark:bg-slate-950">
            <h3 className="text-sm font-semibold text-slate-500 uppercase tracking-wider mb-4 px-2">Your Students</h3>
            {tree.classTeachersWithStudents[0]?.students?.map((student: any) => renderUserRow(student))}
          </div>
        )}

        {/* Unassigned Students Bucket */}
        {tree.unassignedStudents.length > 0 && (userRole === 'principal' || userRole === 'hod' || userRole === 'super_admin') && (
          <AccordionItem value="unassigned_students" className="border-t border-slate-200 dark:border-slate-800">
            <AccordionTrigger className="hover:no-underline px-6 bg-rose-50/50 dark:bg-rose-950/20">
              <div className="flex items-center gap-3 text-left">
                <GraduationCapIcon size={18} className="text-rose-500" />
                <div>
                  <div className="font-semibold text-rose-700 dark:text-rose-400">Unassigned Students</div>
                  <div className="text-xs font-normal text-rose-500/70">{tree.unassignedStudents.length} Students need to be assigned to a class.</div>
                </div>
              </div>
            </AccordionTrigger>
            <AccordionContent className="p-0">
              <div className="bg-white dark:bg-slate-950 p-4 space-y-1">
                {tree.unassignedStudents.map((s: any) => renderUserRow(s, 0, s.department_name))}
              </div>
            </AccordionContent>
          </AccordionItem>
        )}

        {/* Unassigned Staff Bucket */}
        {tree.unassignedStaff.length > 0 && (userRole === 'principal' || userRole === 'super_admin') && (
          <AccordionItem value="unassigned_staff" className="border-t border-slate-200 dark:border-slate-800">
            <AccordionTrigger className="hover:no-underline px-6 bg-orange-50/50 dark:bg-orange-950/20">
              <div className="flex items-center gap-3 text-left">
                <UserIcon size={18} className="text-orange-500" />
                <div>
                  <div className="font-semibold text-orange-700 dark:text-orange-400">Unassigned Staff (No Department)</div>
                  <div className="text-xs font-normal text-orange-500/70">{tree.unassignedStaff.length} Faculty/Teachers need a department assigned.</div>
                </div>
              </div>
            </AccordionTrigger>
            <AccordionContent className="p-0">
              <div className="bg-white dark:bg-slate-950 p-4 space-y-1">
                {tree.unassignedStaff.map((s: any) => renderUserRow(s, 0, s.role))}
              </div>
            </AccordionContent>
          </AccordionItem>
        )}
      </Accordion>
    </Card>
  )
}
