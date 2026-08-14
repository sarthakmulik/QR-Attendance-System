import { useEffect, useState } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { QRCodeSVG } from 'qrcode.react'
import { Users, StopCircle, RefreshCw, Loader2, UserCheck } from 'lucide-react'
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { supabase } from '@/lib/supabase'
import { useSessionRecords } from '@/hooks/queries'
import { toast } from 'sonner'

export default function LiveSession() {
  const { sessionId } = useParams()
  const navigate = useNavigate()
  const [token, setToken] = useState('')
  const [timeRemaining, setTimeRemaining] = useState(15)
  const [isEnding, setIsEnding] = useState(false)
  
  const { data: records, isLoading: recordsLoading } = useSessionRecords(sessionId)

  // Token rotation logic
  useEffect(() => {
    if (!sessionId) return

    const rotateToken = async () => {
      const newToken = Math.random().toString(36).substring(2, 10).toUpperCase()
      const expiresAt = new Date(Date.now() + 15000).toISOString() // 15 seconds validity

      const { error } = await supabase
        .from('attendance_sessions')
        .update({ current_token: newToken, token_expires_at: expiresAt })
        .eq('id', sessionId)

      if (!error) {
        setToken(newToken)
        setTimeRemaining(15)
      } else {
        console.error("Failed to rotate token:", error)
      }
    }

    // Initial rotation
    rotateToken()

    // Setup interval to rotate every 10 seconds (giving 5 seconds buffer)
    const rotationInterval = setInterval(rotateToken, 10000)

    // Setup countdown timer
    const countdownInterval = setInterval(() => {
      setTimeRemaining((prev) => (prev > 0 ? prev - 1 : 0))
    }, 1000)

    return () => {
      clearInterval(rotationInterval)
      clearInterval(countdownInterval)
    }
  }, [sessionId])

  const endSession = async () => {
    setIsEnding(true)
    const { error } = await supabase
      .from('attendance_sessions')
      .update({ is_active: false })
      .eq('id', sessionId)
      
    setIsEnding(false)
    if (error) {
      toast.error('Failed to end session')
    } else {
      toast.success('Lecture ended successfully')
      navigate('/faculty/lectures')
    }
  }

  if (!sessionId) return null

  // The payload that the student will scan
  const qrPayload = JSON.stringify({
    sessionId,
    token
  })

  return (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-slate-900 dark:text-white tracking-tight flex items-center gap-3">
            <span className="relative flex h-3 w-3">
              <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-red-400 opacity-75"></span>
              <span className="relative inline-flex rounded-full h-3 w-3 bg-red-500"></span>
            </span>
            Live Lecture
          </h1>
          <p className="text-slate-500 text-sm mt-1">Students can scan the QR code to mark attendance.</p>
        </div>
        <Button 
          variant="destructive" 
          onClick={endSession} 
          disabled={isEnding}
          className="gap-2"
        >
          {isEnding ? <Loader2 size={16} className="animate-spin" /> : <StopCircle size={16} />}
          End Lecture
        </Button>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* QR Code Section */}
        <Card className="lg:col-span-2 border-none shadow-sm flex flex-col">
          <CardHeader className="border-b border-slate-100">
            <CardTitle className="text-center">Scan to mark attendance</CardTitle>
            <CardDescription className="text-center">
              Please point your camera at the screen. Code refreshes automatically.
            </CardDescription>
          </CardHeader>
          <CardContent className="flex-1 flex flex-col items-center justify-center py-12">
            <div className="bg-white p-6 rounded-2xl shadow-sm border border-slate-100 relative">
              {token ? (
                <QRCodeSVG 
                  value={qrPayload} 
                  size={300}
                  level="H"
                  includeMargin={false}
                  imageSettings={{
                    src: "/vite.svg", // Replace with app logo if available
                    x: undefined,
                    y: undefined,
                    height: 40,
                    width: 40,
                    excavate: true,
                  }}
                />
              ) : (
                <div className="w-[300px] h-[300px] flex items-center justify-center bg-slate-50 rounded-xl">
                  <Loader2 className="w-10 h-10 animate-spin text-primary" />
                </div>
              )}
              
              {/* Progress Bar for Token Rotation */}
              <div className="absolute -bottom-6 left-0 right-0 h-1.5 bg-slate-100 rounded-full overflow-hidden">
                <div 
                  className="h-full bg-primary transition-all duration-1000 ease-linear"
                  style={{ width: `${(timeRemaining / 15) * 100}%` }}
                />
              </div>
            </div>
            <div className="mt-10 flex items-center gap-2 text-sm font-medium text-slate-500">
              <RefreshCw size={14} className={timeRemaining <= 5 ? 'animate-spin text-amber-500' : ''} />
              Code refreshes in {timeRemaining}s
            </div>
          </CardContent>
        </Card>

        {/* Live Attendance List */}
        <Card className="border-none shadow-sm flex flex-col h-[600px]">
          <CardHeader className="border-b border-slate-100 pb-4">
            <div className="flex items-center justify-between">
              <CardTitle className="text-lg flex items-center gap-2">
                <Users size={18} className="text-primary" />
                Present Students
              </CardTitle>
              <div className="bg-green-100 text-green-700 font-bold px-3 py-1 rounded-full text-sm">
                {records?.length || 0}
              </div>
            </div>
          </CardHeader>
          <CardContent className="flex-1 overflow-y-auto p-0">
            {recordsLoading ? (
              <div className="flex justify-center p-8">
                <Loader2 className="w-6 h-6 animate-spin text-primary" />
              </div>
            ) : records?.length === 0 ? (
              <div className="flex flex-col items-center justify-center h-full text-slate-400 p-8 text-center">
                <UserCheck size={48} className="mb-4 opacity-20" />
                <p>Waiting for students to scan...</p>
              </div>
            ) : (
              <div className="divide-y divide-slate-100">
                {records?.map((record: any) => (
                  <div key={record.id} className="p-4 flex items-center gap-3 animate-in fade-in slide-in-from-left-2">
                    <div className="w-8 h-8 rounded-full bg-primary/10 flex items-center justify-center text-primary font-bold text-xs">
                      {record.users?.first_name?.[0]}{record.users?.last_name?.[0]}
                    </div>
                    <div className="flex-1 min-w-0">
                      <p className="text-sm font-medium text-slate-900 truncate">
                        {record.users?.first_name} {record.users?.last_name}
                      </p>
                      <p className="text-xs text-slate-500 truncate">{record.users?.email}</p>
                    </div>
                    <div className="text-[10px] font-mono text-slate-400">
                      {new Date(record.scanned_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })}
                    </div>
                  </div>
                ))}
              </div>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  )
}
