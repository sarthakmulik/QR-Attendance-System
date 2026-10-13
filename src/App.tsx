import { BrowserRouter as Router, Routes, Route, Navigate } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { Toaster } from 'sonner'
import { AuthProvider } from './context/AuthContext'
import Login from './pages/Login'
import Signup from './pages/Signup'
import ProtectedRoute from './components/layout/ProtectedRoute'
import DashboardLayout from './components/layout/DashboardLayout'
import Dashboard from './pages/Dashboard'
import Colleges from './pages/admin/Colleges'
import Departments from './pages/admin/Departments'
import Users from './pages/admin/Users'
import Subjects from './pages/admin/Subjects'
import Timetable from './pages/admin/Timetable'
import Students from './pages/admin/Students'
import Lectures from './pages/faculty/Lectures'
import LiveSession from './pages/faculty/LiveSession'
import Reports from './pages/faculty/Reports'
import Scanner from './pages/student/Scanner'
import ProjectorDisplay from './pages/public/ProjectorDisplay'
import Settings from './pages/Settings'

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 1000 * 60 * 5, // 5 minutes
      retry: 1,
    },
  },
})

function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <Router>
          <Routes>
            {/* Public Routes */}
            <Route path="/login" element={<Login />} />
            <Route path="/signup" element={<Signup />} />
            <Route path="/display/:classId/:token" element={<ProjectorDisplay />} />
            
            {/* Protected Routes */}
            <Route element={<ProtectedRoute />}>
              <Route element={<DashboardLayout />}>
                <Route path="/dashboard" element={<Dashboard />} />
                <Route path="/colleges" element={<Colleges />} />
                <Route path="/departments" element={<Departments />} />
                <Route path="/users" element={<Users />} />
                <Route path="/subjects" element={<Subjects />} />
                <Route path="/timetable" element={<Timetable />} />
                <Route path="/students" element={<Students />} />
              
                {/* Faculty Routes */}
                <Route path="/faculty/lectures" element={<Lectures />} />
                <Route path="/faculty/live-session/:sessionId" element={<LiveSession />} />
                <Route path="/faculty/reports" element={<Reports />} />
              
                {/* Student Routes */}
                <Route path="/student/scan" element={<Scanner />} />
                <Route path="/settings" element={<Settings />} />
              
                <Route path="/" element={<Navigate to="/dashboard" replace />} />
              </Route>
            </Route>
          </Routes>
        </Router>
      </AuthProvider>
      <Toaster position="top-right" richColors />
    </QueryClientProvider>
  )
}

export default App
