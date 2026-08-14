import { useAuth } from '@/context/AuthContext'
import AdminDashboard from '@/components/dashboard/AdminDashboard'
import StudentDashboard from '@/components/dashboard/StudentDashboard'

export default function Dashboard() {
  const { userRole } = useAuth()
  const role = userRole || 'student'

  if (role === 'student') {
    return <StudentDashboard />
  }

  return <AdminDashboard />
}
