import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Button } from '@/components/ui/button'
import { CheckSquare } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/context/AuthContext'

export default function Login() {
  const navigate = useNavigate()
  const { session } = useAuth()
  const [isLoading, setIsLoading] = useState(false)
  const [errorMsg, setErrorMsg] = useState('')

  useEffect(() => {
    if (session) {
      navigate('/dashboard')
    }
  }, [session, navigate])

  const handleLogin = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault()
    setIsLoading(true)
    setErrorMsg('')
    
    const formData = new FormData(e.currentTarget)
    const email = formData.get('email') as string
    const password = formData.get('password') as string

    const { error } = await supabase.auth.signInWithPassword({
      email,
      password,
    })

    if (error) {
      setErrorMsg(error.message)
      setIsLoading(false)
    } else {
      navigate('/dashboard')
    }
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
          <CardTitle className="text-2xl font-bold tracking-tight">Welcome to Attendify</CardTitle>
          <CardDescription className="text-slate-500">
            Sign in to the Enterprise Attendance System
          </CardDescription>
        </CardHeader>
        <CardContent className="pb-8">
          <form onSubmit={handleLogin} className="space-y-5">
            <div className="space-y-2">
              <Label htmlFor="email" className="text-slate-600 font-medium">Email Address</Label>
              <Input 
                id="email"
                name="email"
                type="email" 
                placeholder="admin@college.edu" 
                className="h-11 bg-slate-50/50 border-slate-200 focus-visible:ring-primary" 
                required 
              />
            </div>
            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <Label htmlFor="password" className="text-slate-600 font-medium">Password</Label>
                <a href="#" className="text-sm font-medium text-primary hover:underline">Forgot password?</a>
              </div>
              <Input 
                id="password" 
                name="password"
                type="password" 
                placeholder="••••••••" 
                className="h-11 bg-slate-50/50 border-slate-200 focus-visible:ring-primary" 
                required 
              />
            </div>
            
            {errorMsg && (
              <div className="p-3 rounded-md bg-destructive/15 text-destructive text-sm font-medium">
                {errorMsg}
              </div>
            )}
            
            <Button type="submit" className="w-full h-11 text-base shadow-md transition-all active:scale-[0.98]" disabled={isLoading}>
              {isLoading ? "Signing in..." : "Sign in"}
            </Button>
          </form>
          
          <div className="mt-8 text-center text-sm text-slate-500">
            <p>Don't have an account? <a href="#" className="font-medium text-slate-900 hover:underline">Contact Administrator</a></p>
          </div>
        </CardContent>
      </Card>
    </div>
  )
}
