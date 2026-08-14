import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

export function useColleges() {
  return useQuery({
    queryKey: ['colleges'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('colleges')
        .select('*')
        .order('created_at', { ascending: false })
      if (error) throw error
      return data
    },
  })
}

export function useDepartments() {
  return useQuery({
    queryKey: ['departments'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('departments')
        .select('*, colleges(name)')
        .order('created_at', { ascending: false })
      if (error) throw error
      return data
    },
  })
}

export function useUsers() {
  return useQuery({
    queryKey: ['users'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('users')
        .select(`
          id, first_name, last_name, email, role,
          colleges(name),
          departments(name)
        `)
        .order('created_at', { ascending: false })
      if (error) throw error
      return data
    },
  })
}

export function useUserHierarchy() {
  return useQuery({
    queryKey: ['user-hierarchy'],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_user_hierarchy')
      if (error) throw error
      return data
    },
  })
}

export function useSubjects() {
  return useQuery({
    queryKey: ['subjects'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('subjects')
        .select('*, departments(name)')
        .order('semester', { ascending: true })
      if (error) throw error
      return data
    },
  })
}

export function useTimetable() {
  return useQuery({
    queryKey: ['timetable'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('timetable')
        .select(`
          *,
          classes ( name ),
          subjects ( name, code ),
          users ( first_name, last_name )
        `)
        .order('start_time', { ascending: true })
      if (error) throw error
      return data
    },
  })
}

export function useActiveSessions() {
  return useQuery({
    queryKey: ['active-sessions'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('attendance_sessions')
        .select(`
          *,
          timetable (
            start_time, end_time, room_number,
            classes ( name ),
            subjects ( name, code )
          )
        `)
        .eq('is_active', true)
        .order('created_at', { ascending: false })
      if (error) throw error
      return data
    },
  })
}

export function useSessionRecords(sessionId: string | undefined) {
  return useQuery({
    queryKey: ['attendance-records', sessionId],
    queryFn: async () => {
      if (!sessionId) return []
      const { data, error } = await supabase
        .from('attendance_records')
        .select(`
          *,
          users ( first_name, last_name, email )
        `)
        .eq('session_id', sessionId)
        .order('scanned_at', { ascending: false })
      if (error) throw error
      return data
    },
    enabled: !!sessionId,
    refetchInterval: 5000, // Auto-refresh every 5 seconds for live feed
  })
}

export function useClasses() {
  return useQuery({
    queryKey: ['classes'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('classes')
        .select('*, departments(name)')
        .order('semester', { ascending: true })
      if (error) throw error
      return data
    },
  })
}

export function useStudentStats(studentId: string | undefined) {
  return useQuery({
    queryKey: ['student-stats', studentId],
    queryFn: async () => {
      if (!studentId) return null
      const { data, error } = await supabase
        .from('student_attendance_stats')
        .select('*')
        .eq('student_id', studentId)
        .maybeSingle()
      if (error) throw error
      return data
    },
    enabled: !!studentId,
  })
}

export function useSubjectStats(studentId: string | undefined) {
  return useQuery({
    queryKey: ['subject-stats', studentId],
    queryFn: async () => {
      if (!studentId) return []
      const { data, error } = await supabase
        .from('subject_attendance_stats')
        .select('*')
        .eq('student_id', studentId)
      if (error) throw error
      return data
    },
    enabled: !!studentId,
  })
}

export function useLowAttendanceReport(threshold: number = 75) {
  return useQuery({
    queryKey: ['low-attendance-report', threshold],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('student_attendance_stats')
        .select('*')
        .lt('attendance_percentage', threshold)
        .order('attendance_percentage', { ascending: true })
        .limit(10)
      if (error) throw error
      return data
    },
  })
}

export function useDashboardStats() {
  return useQuery({
    queryKey: ['admin-dashboard-stats'],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_dashboard_stats')
      if (error) throw error
      return data
    },
    refetchInterval: 60000, // 1 minute
  })
}

export function useGlobalRecentScans() {
  return useQuery({
    queryKey: ['admin-recent-scans'],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_recent_scans')
      if (error) throw error
      return data
    },
    refetchInterval: 5000, // 5 seconds live feed
  })
}
