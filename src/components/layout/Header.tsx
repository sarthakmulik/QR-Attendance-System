import { Bell, Search } from 'lucide-react'
import { useAuth } from '@/context/AuthContext'

export default function Header() {
  const { user, userRole } = useAuth()
  
  return (
    <header className="h-16 bg-white dark:bg-slate-950 border-b border-slate-200 dark:border-slate-800 flex items-center justify-between px-6 z-10 shadow-sm">
      <div className="flex items-center bg-slate-100 dark:bg-slate-900 px-3 py-2 rounded-lg w-96 focus-within:ring-2 focus-within:ring-primary/20 transition-all">
        <Search size={18} className="text-slate-400 mr-2" />
        <input 
          type="text" 
          placeholder="Search students, subjects..." 
          className="bg-transparent border-none outline-none text-sm w-full text-slate-700 dark:text-slate-300 placeholder:text-slate-400"
        />
      </div>
      
      <div className="flex items-center gap-4">
        <button className="relative p-2 text-slate-500 hover:bg-slate-100 dark:hover:bg-slate-800 rounded-full transition-colors">
          <Bell size={20} />
          <span className="absolute top-1.5 right-1.5 w-2 h-2 bg-red-500 rounded-full border-2 border-white dark:border-slate-950"></span>
        </button>
        <div className="flex items-center gap-3 border-l border-slate-200 dark:border-slate-800 pl-4">
          <div className="text-right hidden md:block">
            <p className="text-sm font-medium text-slate-700 dark:text-slate-200">
              {user?.user_metadata?.first_name 
                ? `${user.user_metadata.first_name} ${user.user_metadata.last_name}`
                : user?.email}
            </p>
            <p className="text-xs text-slate-500 capitalize">{userRole?.replace('_', ' ') || 'Student'}</p>
          </div>
          <div className="w-9 h-9 rounded-full bg-gradient-to-tr from-primary to-blue-400 text-white flex items-center justify-center font-bold shadow-md uppercase">
            {user?.user_metadata?.first_name 
              ? `${user.user_metadata.first_name[0]}${user.user_metadata.last_name[0]}`
              : user?.email?.[0]}
          </div>
        </div>
      </div>
    </header>
  )
}
