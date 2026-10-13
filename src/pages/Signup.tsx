import { useState, useEffect } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Button } from '@/components/ui/button'
import { CheckSquare } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'

export default function Signup() {
  const navigate = useNavigate()
  const { session } = useAuth()
  const [isLoading, setIsLoading] = useState(false)
  const [errorMsg, setErrorMsg] = useState('')
  const [infoMsg, setInfoMsg] = useState('')

  useEffect(() => {
    if (session) {
      navigate('/dashboard')
    }
  }, [session, navigate])

  const handleSignup = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault()
    setIsLoading(true)
    setErrorMsg('')
    setInfoMsg('')

    const formData = new FormData(e.currentTarget)
    const firstName = (formData.get('first_name') as string).trim()
    const lastName = (formData.get('last_name') as string).trim()
    const email = (formData.get('email') as string).trim().toLowerCase()
    const password = formData.get('password') as string
    const confirmPassword = formData.get('confirm_password') as string

    if (password !== confirmPassword) {
      setErrorMsg('Passwords do not match.')
      setIsLoading(false)
      return
    }

    if (password.length < 8) {
      setErrorMsg('Password must be at least 8 characters.')
      setIsLoading(false)
      return
    }

    const { data: inviteCheck, error: inviteError } = await supabase.rpc('can_signup_with_email', {
      p_email: email,
    })

    const inviteResult = typeof inviteCheck === 'string' ? JSON.parse(inviteCheck) : inviteCheck
    if (!inviteError && inviteResult && inviteResult.allowed === false) {
      setErrorMsg(inviteResult.message || 'This email has not been added by a Principal or HOD yet.')
      setIsLoading(false)
      return
    }

    const { data, error } = await supabase.auth.signUp({
      email,
      password,
      options: {
        data: {
          first_name: firstName,
          last_name: lastName,
        },
      },
    })

    if (error) {
      setErrorMsg(error.message)
      setIsLoading(false)
      return
    }

    if (!data.session) {
      setInfoMsg('Account created. Check your email to confirm, then sign in. Your assigned role will apply automatically.')
      setIsLoading(false)
      return
    }

    navigate('/dashboard')
  }

  return (
    <div className="min-h-screen bg-slate-50 dark:bg-slate-950 flex items-center justify-center p-4">
      <div className="absolute inset-0 bg-[linear-gradient(to_right,#80808012_1px,transparent_1px),linear-gradient(to_bottom,#80808012_1px,transparent_1px)] bg-[size:24px_24px]"></div>
      <div className="absolute inset-0 bg-slate-50/50 dark:bg-slate-950/50 backdrop-blur-[1px]"></div>

      <Card className="w-full max-w-md relative z-10 border-none shadow-2xl bg-white/90 dark:bg-slate-900/90 backdrop-blur-xl">
        <CardHeader className="space-y-3 text-center pb-6 pt-8">
          <div className="mx-auto bg-primary/10 w-16 h-16 rounded-2xl flex items-center justify-center mb-2">
            <CheckSquare size={32} className="text-primary" />
          </div>
          <CardTitle className="text-2xl font-bold tracking-tight">Create your account</CardTitle>
          <CardDescription className="text-slate-500">
            Use the email your Principal or HOD added so your role is assigned automatically.
          </CardDescription>
        </CardHeader>
        <CardContent className="pb-8">
          <form onSubmit={handleSignup} className="space-y-4">
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-2">
                <Label htmlFor="first_name" className="text-slate-600 font-medium">First Name</Label>
                <Input id="first_name" name="first_name" placeholder="John" className="h-11 bg-slate-50/50 border-slate-200" required />
              </div>
              <div className="space-y-2">
                <Label htmlFor="last_name" className="text-slate-600 font-medium">Last Name</Label>
                <Input id="last_name" name="last_name" placeholder="Doe" className="h-11 bg-slate-50/50 border-slate-200" required />
              </div>
            </div>
            <div className="space-y-2">
              <Label htmlFor="email" className="text-slate-600 font-medium">Email Address</Label>
              <Input
                id="email"
                name="email"
                type="email"
                placeholder="you@college.edu"
                className="h-11 bg-slate-50/50 border-slate-200 focus-visible:ring-primary"
                required
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="password" className="text-slate-600 font-medium">Password</Label>
              <Input
                id="password"
                name="password"
                type="password"
                placeholder="••••••••"
                className="h-11 bg-slate-50/50 border-slate-200"
                required
                minLength={8}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="confirm_password" className="text-slate-600 font-medium">Confirm Password</Label>
              <Input
                id="confirm_password"
                name="confirm_password"
                type="password"
                placeholder="••••••••"
                className="h-11 bg-slate-50/50 border-slate-200"
                required
                minLength={8}
              />
            </div>

            {errorMsg && (
              <div className="p-3 rounded-md bg-destructive/15 text-destructive text-sm font-medium">
                {errorMsg}
              </div>
            )}
            {infoMsg && (
              <div className="p-3 rounded-md bg-emerald-50 text-emerald-700 text-sm font-medium">
                {infoMsg}
              </div>
            )}

            <Button type="submit" className="w-full h-11 text-base shadow-md transition-all active:scale-[0.98]" disabled={isLoading}>
              {isLoading ? 'Creating account...' : 'Sign up'}
            </Button>
          </form>

          <div className="mt-8 text-center text-sm text-slate-500">
            <p>
              Already have an account?{' '}
              <Link to="/login" className="font-medium text-slate-900 hover:underline">
                Sign in
              </Link>
            </p>
          </div>
        </CardContent>
      </Card>
    </div>
  )
}
