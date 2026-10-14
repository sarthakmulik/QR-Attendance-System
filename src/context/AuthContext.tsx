import { createContext, useContext, useEffect, useState } from 'react'
import type { Session, User } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'

type AuthContextType = {
  session: Session | null
  user: User | null
  userRole: string | null
  userCollegeId: string | null
  userDepartmentId: string | null
  /** True when the account exists but an admin has not assigned a role yet */
  rolePending: boolean
  loading: boolean
  signOut: () => Promise<void>
}

const AuthContext = createContext<AuthContextType | undefined>(undefined)

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [user, setUser] = useState<User | null>(null)
  const [userRole, setUserRole] = useState<string | null>(null)
  const [userCollegeId, setUserCollegeId] = useState<string | null>(null)
  const [userDepartmentId, setUserDepartmentId] = useState<string | null>(null)
  const [rolePending, setRolePending] = useState(false)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    supabase.auth.getSession().then(({ data: { session } }) => {
      setSession(session)
      setUser(session?.user ?? null)
      if (session?.user) fetchUserData(session.user.id)
      else setLoading(false)
    })

    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, session) => {
      setSession(session)
      setUser(session?.user ?? null)
      if (session?.user) fetchUserData(session.user.id)
      else {
        setUserRole(null)
        setUserCollegeId(null)
        setUserDepartmentId(null)
        setRolePending(false)
        setLoading(false)
      }
    })

    return () => subscription.unsubscribe()
  }, [])

  const fetchUserData = async (userId: string, attempt = 0) => {
    try {
      let data: { role: any; college_id: any; department_id: any; role_assigned?: any } | null = null
      let error: any = null

      const primary = await supabase
        .from('users')
        .select('role, college_id, department_id, role_assigned')
        .eq('id', userId)
        .maybeSingle()
      data = primary.data as typeof data
      error = primary.error

      // Graceful fallback if the role_assigned migration hasn't been applied yet
      if (error && /role_assigned/i.test(error.message || '')) {
        const retry = await supabase
          .from('users')
          .select('role, college_id, department_id')
          .eq('id', userId)
          .maybeSingle()
        data = retry.data as typeof data
        error = retry.error
      }

      if (!error && data) {
        const profile = data as { role: any; college_id: any; department_id: any; role_assigned?: any }
        setUserRole(profile.role)
        setUserCollegeId(profile.college_id)
        setUserDepartmentId(profile.department_id)
        setRolePending(profile.role_assigned === false)
        setLoading(false)
        return
      }

      // New signups can race the auth trigger that writes public.users
      if (attempt < 6) {
        setTimeout(() => fetchUserData(userId, attempt + 1), 400)
        return
      }
      // No profile row after all retries: the auth trigger likely failed.
      // Show the "contact your administrator" screen instead of a fake student UI.
      setRolePending(true)
    } catch (error) {
      console.error('Error fetching user data:', error)
      if (attempt < 6) {
        setTimeout(() => fetchUserData(userId, attempt + 1), 400)
        return
      }
      setRolePending(true)
    }
    setLoading(false)
  }

  const signOut = async () => {
    await supabase.auth.signOut()
  }

  return (
    <AuthContext.Provider value={{ session, user, userRole, userCollegeId, userDepartmentId, rolePending, loading, signOut }}>
      {children}
    </AuthContext.Provider>
  )
}

export const useAuth = () => {
  const context = useContext(AuthContext)
  if (context === undefined) {
    throw new Error('useAuth must be used within an AuthProvider')
  }
  return context
}
