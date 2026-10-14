import { Navigate, Outlet } from 'react-router-dom'
import { useAuth } from '@/context/AuthContext'
import { Loader2 } from 'lucide-react'

/**
 * Guards a route group by role (defense-in-depth on top of database RLS).
 * Renders the outlet only for the listed roles; otherwise redirects to the
 * dashboard. Nested inside <ProtectedRoute /> so authentication is handled
 * by the parent.
 */
export default function RoleRoute({ roles }: { roles: string[] }) {
  const { userRole, loading } = useAuth()

  if (loading) {
    return (
      <div className="flex flex-col items-center justify-center h-full min-h-[50vh]">
        <Loader2 className="w-8 h-8 animate-spin text-primary mb-3" />
        <p className="text-slate-500 text-sm animate-pulse">Verifying access...</p>
      </div>
    )
  }

  if (!userRole || !roles.includes(userRole)) {
    return <Navigate to="/dashboard" replace />
  }

  return <Outlet />
}
