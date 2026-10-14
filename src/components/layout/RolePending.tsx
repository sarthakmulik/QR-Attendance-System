import { useAuth } from '@/context/AuthContext'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { UserCog, LogOut, Mail } from 'lucide-react'

export default function RolePending() {
  const { user, signOut } = useAuth()

  return (
    <div className="min-h-screen bg-slate-50 dark:bg-slate-950 flex items-center justify-center p-4">
      <Card className="w-full max-w-lg border-none shadow-xl text-center">
        <CardContent className="pt-10 pb-8 px-8">
          <div className="mx-auto bg-amber-100 dark:bg-amber-900/30 w-16 h-16 rounded-2xl flex items-center justify-center mb-5">
            <UserCog size={32} className="text-amber-600 dark:text-amber-400" />
          </div>
          <CardHeader className="p-0">
            <CardTitle className="text-2xl font-bold tracking-tight">Role Not Assigned Yet</CardTitle>
            <CardDescription className="text-slate-500 mt-2">
              Your account has been created successfully, but an administrator has not assigned you a role yet.
            </CardDescription>
          </CardHeader>

          <div className="mt-6 text-left bg-slate-50 dark:bg-slate-900 rounded-xl p-5 space-y-3 text-sm text-slate-600 dark:text-slate-300">
            <p className="font-medium text-slate-900 dark:text-white flex items-center gap-2">
              <Mail size={16} className="text-primary" />
              What should I do next?
            </p>
            <ol className="list-decimal list-inside space-y-2">
              <li>Contact your college <span className="font-medium">Principal</span>, <span className="font-medium">HOD</span>, or <span className="font-medium">Class Teacher</span>.</li>
              <li>Ask them to add your account (<span className="font-mono text-xs">{user?.email}</span>) in User Management so a role is assigned to you.</li>
              <li>Sign out and sign back in — your dashboard will load automatically once your role is assigned.</li>
            </ol>
          </div>

          <Button onClick={() => signOut()} variant="outline" className="mt-8 gap-2">
            <LogOut size={16} />
            Sign Out
          </Button>
        </CardContent>
      </Card>
    </div>
  )
}
