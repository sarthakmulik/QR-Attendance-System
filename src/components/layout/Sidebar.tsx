import { NavLink } from 'react-router-dom'
import { LayoutDashboard, Users, BookOpen, Calendar, Settings, LogOut, CheckSquare, Building2, Building, GraduationCap, QrCode, Clock, Video, FileSpreadsheet } from 'lucide-react'
import { cn } from '@/lib/utils'
import { useAuth } from '@/context/AuthContext'
import { supabase } from '@/lib/supabase'

export default function Sidebar() {
  const { userRole, signOut } = useAuth()
  // Default to student if role is still loading or null to be safe
  const currentRole = userRole || 'student'

  const navItems = [
    { name: 'Dashboard', href: '/dashboard', icon: LayoutDashboard, roles: ['super_admin', 'principal', 'hod', 'class_teacher', 'faculty', 'student'] },
    { name: 'Colleges', href: '/colleges', icon: Building2, roles: ['super_admin'] },
    { name: 'Departments', href: '/departments', icon: Building, roles: ['super_admin', 'principal'] },
    { name: 'Users', href: '/users', icon: Users, roles: ['super_admin', 'principal', 'hod'] },
    { name: 'Subjects', href: '/subjects', icon: BookOpen, roles: ['super_admin', 'principal', 'hod'] },
    { name: 'Master Timetable', href: '/timetable', icon: Calendar, roles: ['super_admin', 'principal', 'hod'] },
    { name: 'My Lectures', href: '/faculty/lectures', icon: Clock, roles: ['class_teacher', 'faculty', 'super_admin'] },
    { name: 'Reports', href: '/faculty/reports', icon: FileSpreadsheet, roles: ['super_admin', 'principal', 'hod', 'class_teacher', 'faculty'] },
    { name: 'Students', href: '/students', icon: GraduationCap, roles: ['super_admin', 'principal', 'hod', 'class_teacher'] },
    { name: 'Scan QR', href: '/student/scan', icon: QrCode, roles: ['student', 'super_admin'] },
    { name: 'Settings', href: '/settings', icon: Settings, roles: ['super_admin', 'principal', 'hod', 'class_teacher', 'faculty', 'student'] },
  ]

  const visibleLinks = navItems.filter(item => item.roles.includes(currentRole))

  const handleSignOut = async () => {
    await signOut()
    // No need to redirect via window.location.href, ProtectedRoute will handle it!
  }

  return (
    <aside className="w-64 bg-white dark:bg-slate-950 border-r border-slate-200 dark:border-slate-800 flex flex-col">
      <div className="h-16 flex items-center px-6 border-b border-slate-200 dark:border-slate-800">
        <div className="flex items-center gap-2 text-primary font-bold text-xl tracking-tight">
          <div className="bg-primary text-white p-1.5 rounded-lg">
            <CheckSquare size={20} />
          </div>
          <span>Attendify</span>
        </div>
      </div>
      
      <div className="flex-1 overflow-y-auto py-4 px-3 space-y-1">
        <div className="px-3 text-xs font-semibold text-slate-500 uppercase tracking-wider mb-2">Main Menu</div>
        {visibleLinks.map((link) => {
          const Icon = link.icon
          return (
            <NavLink
              key={link.name}
              to={link.href}
              className={({ isActive }) => cn(
                "flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium transition-all duration-200",
                isActive 
                  ? "bg-primary/10 text-primary" 
                  : "text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-800 dark:hover:text-slate-100"
              )}
            >
              <Icon size={18} />
              {link.name}
            </NavLink>
          )
        })}
      </div>
      
      <div className="p-4 border-t border-slate-200 dark:border-slate-800">
        <button onClick={handleSignOut} className="flex w-full items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium text-slate-600 hover:bg-red-50 hover:text-red-600 transition-colors">
          <LogOut size={18} />
          Sign Out
        </button>
      </div>
    </aside>
  )
}
