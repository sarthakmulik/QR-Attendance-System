import { useState, useEffect } from 'react'
import { useAuth } from '@/context/AuthContext'
import { Card } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Switch } from '@/components/ui/switch'
import { Loader2, Save, User as UserIcon, Shield, Bell, Key, LogOut } from 'lucide-react'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { useMutation } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { toast } from 'sonner'
import { useNavigate } from 'react-router-dom'

const profileSchema = z.object({
  first_name: z.string().min(2, 'First name is too short'),
  last_name: z.string().min(2, 'Last name is too short'),
})
type ProfileFormValues = z.infer<typeof profileSchema>

export default function Settings() {
  const { user, userRole, signOut } = useAuth()
  const navigate = useNavigate()
  
  // Simulated preferences
  const [emailNotifs, setEmailNotifs] = useState(true)
  const [smsNotifs, setSmsNotifs] = useState(false)
  const [darkMode, setDarkMode] = useState(true)

  const form = useForm<ProfileFormValues>({
    resolver: zodResolver(profileSchema),
    defaultValues: {
      first_name: user?.user_metadata?.first_name || '',
      last_name: user?.user_metadata?.last_name || '',
    },
  })

  useEffect(() => {
    if (!user) return
    const fetchUser = async () => {
      const { data } = await supabase
        .from('users')
        .select('first_name, last_name')
        .eq('id', user.id)
        .single()
      if (data) {
        form.reset({
          first_name: data.first_name || user?.user_metadata?.first_name || '',
          last_name: data.last_name || user?.user_metadata?.last_name || '',
        })
      }
    }
    fetchUser()
  }, [user])

  const updateProfileMutation = useMutation({
    mutationFn: async (values: ProfileFormValues) => {
      // Update Auth Metadata
      const { data: authData, error: authError } = await supabase.auth.updateUser({
        data: { first_name: values.first_name, last_name: values.last_name }
      })
      if (authError) throw authError

      // Update Public Users Table
      const { error: dbError } = await supabase
        .from('users')
        .update({ first_name: values.first_name, last_name: values.last_name })
        .eq('id', user?.id)
        
      if (dbError) throw dbError
      return authData
    },
    onSuccess: () => toast.success('Profile updated successfully'),
    onError: (err: any) => toast.error(err.message || 'Failed to update profile')
  })

  const handleSignOut = async () => {
    try {
      await signOut()
      navigate('/login')
    } catch (error: any) {
      toast.error('Error signing out')
    }
  }

  const roleLabels: Record<string, string> = {
    super_admin: 'Super Administrator',
    principal: 'College Principal',
    hod: 'Head of Department',
    class_teacher: 'Class Teacher',
    faculty: 'Faculty Member',
    student: 'Student'
  }

  return (
    <div className="max-w-4xl mx-auto space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div>
        <h1 className="text-2xl font-bold text-slate-900 dark:text-white tracking-tight">Account Settings</h1>
        <p className="text-slate-500 text-sm mt-1">Manage your profile, preferences, and account security.</p>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
        
        {/* LEFT COLUMN: Profile info & Security */}
        <div className="space-y-6">
          <Card className="p-6 border-none shadow-sm text-center">
            <div className="w-24 h-24 bg-gradient-to-tr from-indigo-500 to-purple-500 rounded-full mx-auto flex items-center justify-center shadow-lg mb-4">
              <span className="text-3xl font-bold text-white">
                {user?.user_metadata?.first_name?.charAt(0) || 'U'}
                {user?.user_metadata?.last_name?.charAt(0) || ''}
              </span>
            </div>
            <h2 className="text-lg font-bold text-slate-900 dark:text-white">
              {user?.user_metadata?.first_name} {user?.user_metadata?.last_name}
            </h2>
            <p className="text-sm text-slate-500 mb-4">{user?.email}</p>
            
            <div className="inline-flex items-center gap-2 bg-indigo-50 dark:bg-indigo-900/30 text-indigo-700 dark:text-indigo-400 px-3 py-1.5 rounded-full text-xs font-semibold uppercase tracking-wider">
              <Shield size={14} />
              {roleLabels[userRole || 'student']}
            </div>
          </Card>

          <Card className="p-6 border-none shadow-sm">
            <h3 className="font-semibold flex items-center gap-2 mb-4 text-slate-900 dark:text-white">
              <Key size={18} className="text-slate-400" />
              Security
            </h3>
            <div className="space-y-4">
              <Button variant="outline" className="w-full justify-start text-slate-600 dark:text-slate-300">
                Change Password
              </Button>
              <Button variant="outline" className="w-full justify-start text-slate-600 dark:text-slate-300">
                Two-Factor Authentication
              </Button>
              <Button variant="destructive" className="w-full justify-start gap-2 mt-4" onClick={handleSignOut}>
                <LogOut size={16} /> Sign Out
              </Button>
            </div>
          </Card>
        </div>

        {/* RIGHT COLUMN: Forms and Toggles */}
        <div className="md:col-span-2 space-y-6">
          
          <Card className="p-6 border-none shadow-sm">
            <h3 className="font-semibold flex items-center gap-2 mb-6 text-slate-900 dark:text-white border-b border-slate-100 dark:border-slate-800 pb-4">
              <UserIcon size={18} className="text-indigo-500" />
              Personal Information
            </h3>
            <form onSubmit={form.handleSubmit((v) => updateProfileMutation.mutate(v))} className="space-y-4">
              <div className="grid grid-cols-2 gap-4">
                <div className="space-y-2">
                  <Label htmlFor="first_name">First Name</Label>
                  <Input id="first_name" {...form.register('first_name')} />
                  {form.formState.errors.first_name && (
                    <p className="text-xs text-destructive">{form.formState.errors.first_name.message}</p>
                  )}
                </div>
                <div className="space-y-2">
                  <Label htmlFor="last_name">Last Name</Label>
                  <Input id="last_name" {...form.register('last_name')} />
                  {form.formState.errors.last_name && (
                    <p className="text-xs text-destructive">{form.formState.errors.last_name.message}</p>
                  )}
                </div>
              </div>
              <div className="space-y-2">
                <Label htmlFor="email">Email Address</Label>
                <Input id="email" value={user?.email} disabled className="bg-slate-50 dark:bg-slate-900/50 text-slate-500" />
                <p className="text-xs text-slate-400">Contact your administrator to change your email address.</p>
              </div>

              <div className="pt-4 flex justify-end">
                <Button type="submit" disabled={updateProfileMutation.isPending} className="gap-2 shadow-sm">
                  {updateProfileMutation.isPending ? <Loader2 size={16} className="animate-spin" /> : <Save size={16} />}
                  Save Changes
                </Button>
              </div>
            </form>
          </Card>

          <Card className="p-6 border-none shadow-sm">
            <h3 className="font-semibold flex items-center gap-2 mb-6 text-slate-900 dark:text-white border-b border-slate-100 dark:border-slate-800 pb-4">
              <Bell size={18} className="text-amber-500" />
              Preferences & Notifications
            </h3>
            <div className="space-y-6">
              
              <div className="flex items-center justify-between">
                <div className="space-y-0.5">
                  <Label className="text-base font-medium">Email Notifications</Label>
                  <p className="text-sm text-slate-500">Receive daily attendance reports and system alerts via email.</p>
                </div>
                <Switch checked={emailNotifs} onCheckedChange={setEmailNotifs} />
              </div>

              <div className="flex items-center justify-between">
                <div className="space-y-0.5">
                  <Label className="text-base font-medium">SMS Alerts</Label>
                  <p className="text-sm text-slate-500">Receive critical alerts (e.g. absent notifications) via SMS.</p>
                </div>
                <Switch checked={smsNotifs} onCheckedChange={setSmsNotifs} />
              </div>

              <div className="flex items-center justify-between">
                <div className="space-y-0.5">
                  <Label className="text-base font-medium">Dark Mode Appearance</Label>
                  <p className="text-sm text-slate-500">Toggle between light and dark UI themes.</p>
                </div>
                <Switch checked={darkMode} onCheckedChange={(val) => {
                  setDarkMode(val)
                  document.documentElement.classList.toggle('dark', val)
                }} />
              </div>

            </div>
          </Card>

        </div>
      </div>
    </div>
  )
}
