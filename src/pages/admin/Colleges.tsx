import { useState } from 'react'
import { Plus, MoreVertical, Building2, Loader2 } from 'lucide-react'
import { Card } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger } from '@/components/ui/dialog'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { useColleges } from '@/hooks/queries'

const collegeSchema = z.object({
  name: z.string().min(2, 'Name is too short'),
  address: z.string().optional(),
  contact_email: z.string().email('Invalid email address').optional().or(z.literal('')),
})

type CollegeFormValues = z.infer<typeof collegeSchema>

export default function Colleges() {
  const [isDialogOpen, setIsDialogOpen] = useState(false)
  const queryClient = useQueryClient()
  const { data: colleges, isLoading } = useColleges()

  const form = useForm<CollegeFormValues>({
    resolver: zodResolver(collegeSchema),
    defaultValues: {
      name: '',
      address: '',
      contact_email: '',
    },
  })

  const createCollegeMutation = useMutation({
    mutationFn: async (values: CollegeFormValues) => {
      const { data, error } = await supabase.rpc('create_college_with_admin', {
        p_name: values.name,
        p_address: values.address || null,
        p_contact_email: values.contact_email || null,
      })
      
      if (error) throw error
      return data
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['colleges'] })
      toast.success('College created successfully')
      setIsDialogOpen(false)
      form.reset()
    },
    onError: (error: any) => {
      toast.error(error.message || 'Failed to create college')
    },
  })

  const onSubmit = (values: CollegeFormValues) => {
    createCollegeMutation.mutate(values)
  }

  return (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-slate-900 dark:text-white tracking-tight">Colleges Management</h1>
          <p className="text-slate-500 text-sm mt-1">Manage partner colleges and universities across the platform.</p>
        </div>
        
        <Dialog open={isDialogOpen} onOpenChange={setIsDialogOpen}>
          <DialogTrigger asChild>
            <Button className="gap-2 shadow-sm">
              <Plus size={16} />
              Add College
            </Button>
          </DialogTrigger>
          <DialogContent className="sm:max-w-[425px]">
            <form onSubmit={form.handleSubmit(onSubmit)}>
              <DialogHeader>
                <DialogTitle>Add New College</DialogTitle>
                <DialogDescription>
                  Enter the details of the college to add it to the platform.
                </DialogDescription>
              </DialogHeader>
              <div className="grid gap-4 py-4">
                <div className="space-y-2">
                  <Label htmlFor="name">College Name *</Label>
                  <Input id="name" placeholder="e.g. University of Technology" {...form.register('name')} />
                  {form.formState.errors.name && (
                    <p className="text-xs text-destructive">{form.formState.errors.name.message}</p>
                  )}
                </div>
                <div className="space-y-2">
                  <Label htmlFor="contact_email">Contact Email</Label>
                  <Input id="contact_email" type="email" placeholder="admin@univ.edu" {...form.register('contact_email')} />
                  {form.formState.errors.contact_email && (
                    <p className="text-xs text-destructive">{form.formState.errors.contact_email.message}</p>
                  )}
                </div>
                <div className="space-y-2">
                  <Label htmlFor="address">Address</Label>
                  <Input id="address" placeholder="123 Campus Dr" {...form.register('address')} />
                </div>
              </div>
              <DialogFooter>
                <Button type="button" variant="outline" onClick={() => setIsDialogOpen(false)}>Cancel</Button>
                <Button type="submit" disabled={createCollegeMutation.isPending}>
                  {createCollegeMutation.isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                  Save College
                </Button>
              </DialogFooter>
            </form>
          </DialogContent>
        </Dialog>
      </div>

      <Card className="border-none shadow-sm overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm text-left">
            <thead className="text-xs text-slate-500 uppercase bg-slate-50/50 dark:bg-slate-900/50 border-b border-slate-200 dark:border-slate-800">
              <tr>
                <th className="px-6 py-4 font-semibold">College Name</th>
                <th className="px-6 py-4 font-semibold">Contact Email</th>
                <th className="px-6 py-4 font-semibold">Joined Date</th>
                <th className="px-6 py-4 text-right font-semibold">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100 dark:divide-slate-800 bg-white dark:bg-slate-950">
              {isLoading ? (
                <tr>
                  <td colSpan={4} className="px-6 py-8 text-center text-slate-500">
                    <Loader2 className="w-6 h-6 animate-spin mx-auto mb-2 text-primary" />
                    Loading colleges...
                  </td>
                </tr>
              ) : !colleges || colleges.length === 0 ? (
                <tr>
                  <td colSpan={4} className="px-6 py-12 text-center">
                    <div className="flex flex-col items-center justify-center">
                      <div className="bg-slate-100 dark:bg-slate-900 p-4 rounded-full mb-4">
                        <Building2 className="w-8 h-8 text-slate-400" />
                      </div>
                      <h3 className="text-lg font-semibold text-slate-900 dark:text-white">No colleges found</h3>
                      <p className="text-slate-500 max-w-sm mt-1">Get started by adding the first college to the platform.</p>
                    </div>
                  </td>
                </tr>
              ) : (
                colleges.map((college: any) => (
                  <tr key={college.id} className="hover:bg-slate-50 dark:hover:bg-slate-900/50 transition-colors">
                    <td className="px-6 py-4 font-medium text-slate-900 dark:text-slate-100">
                      <div className="flex items-center gap-3">
                        <div className="w-8 h-8 rounded-md bg-primary/10 flex items-center justify-center text-primary font-bold">
                          {college.name.charAt(0)}
                        </div>
                        {college.name}
                      </div>
                    </td>
                    <td className="px-6 py-4 text-slate-600 dark:text-slate-400">
                      {college.contact_email || '—'}
                    </td>
                    <td className="px-6 py-4 text-slate-600 dark:text-slate-400">
                      {new Date(college.created_at).toLocaleDateString()}
                    </td>
                    <td className="px-6 py-4 text-right">
                      <Button variant="ghost" size="icon" className="text-slate-400 hover:text-slate-600">
                        <MoreVertical size={16} />
                      </Button>
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </Card>
    </div>
  )
}
