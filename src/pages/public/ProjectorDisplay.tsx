import { useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'
import { QRCodeSVG } from 'qrcode.react'
import { MonitorPlay, Loader2, StopCircle } from 'lucide-react'
import { supabase } from '@/lib/supabase'

export default function ProjectorDisplay() {
  const { classId, token } = useParams()
  
  const [session, setSession] = useState<any>(null)
  const [error, setError] = useState<string | null>(null)
  const [isLoading, setIsLoading] = useState(true)
  
  // Local TOTP state
  const [currentToken, setCurrentToken] = useState('')
  const [progressPercent, setProgressPercent] = useState(100)
  
  useEffect(() => {
    if (session?.session_secret) {
      const rotateToken = async () => {
        const now = new Date()
        
        // Auto-end session if expires_at is reached
        if (session.expires_at && now.getTime() > new Date(session.expires_at).getTime()) {
          setSession(null)
          return
        }

        const currentWindow = Math.floor(now.getTime() / 1000 / 10)
        
        const msgBuffer = new TextEncoder().encode(session.session_secret + currentWindow.toString())
        const hashBuffer = await crypto.subtle.digest('SHA-256', msgBuffer)
        const hashArray = Array.from(new Uint8Array(hashBuffer))
        const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('')
        
        setCurrentToken(hashHex.substring(0, 8))
        
        const nextWindowTime = (currentWindow + 1) * 10 * 1000
        const remainingMs = nextWindowTime - now.getTime()
        setProgressPercent((remainingMs / 10000) * 100)
      }

      rotateToken()
      const interval = setInterval(rotateToken, 100) // Update very frequently for smooth progress bar
      return () => clearInterval(interval)
    }
  }, [session])

  const fetchCurrentSession = async () => {
    try {
      const { data, error: rpcError } = await supabase.rpc('get_projector_session', {
        p_class_id: classId,
        p_display_token: token
      })

      if (rpcError) throw rpcError
      
      if (!data.success) {
        setError(data.message)
      } else {
        setSession(data.session)
      }
    } catch (err: any) {
      console.error(err)
      setError("Connection error. Please refresh the page.")
    } finally {
      setIsLoading(false)
    }
  }

  useEffect(() => {
    if (!classId || !token) {
      setError("Invalid URL parameters.")
      setIsLoading(false)
      return
    }

    // Initial fetch
    fetchCurrentSession()

    // Robust Polling: Poll every 3 seconds to check if a new session started or ended.
    // The actual QR code rotates offline using TOTP!
    const pollingInterval = setInterval(() => {
      fetchCurrentSession()
    }, 3000)

    return () => {
      clearInterval(pollingInterval)
    }
  }, [classId, token])

  if (isLoading) {
    return (
      <div className="min-h-screen bg-slate-950 flex flex-col items-center justify-center text-white">
        <Loader2 className="w-16 h-16 animate-spin text-blue-500 mb-6" />
        <h1 className="text-2xl font-semibold animate-pulse">Initializing Smart Projector...</h1>
      </div>
    )
  }

  if (error) {
    return (
      <div className="min-h-screen bg-slate-950 flex flex-col items-center justify-center text-white p-8 text-center">
        <div className="bg-red-500/10 p-6 rounded-full mb-6">
          <StopCircle className="w-20 h-20 text-red-500" />
        </div>
        <h1 className="text-4xl font-bold mb-4 text-red-400">Connection Denied</h1>
        <p className="text-xl text-slate-400 max-w-lg">{error}</p>
      </div>
    )
  }

  // IDLE STATE: No active session
  if (!session) {
    return (
      <div className="min-h-screen bg-slate-950 flex flex-col items-center justify-center text-white relative overflow-hidden">
        {/* Animated background elements */}
        <div className="absolute top-1/4 left-1/4 w-96 h-96 bg-blue-500/10 rounded-full blur-3xl animate-pulse"></div>
        <div className="absolute bottom-1/4 right-1/4 w-[30rem] h-[30rem] bg-indigo-500/10 rounded-full blur-3xl animate-pulse" style={{ animationDelay: '1s' }}></div>
        
        <div className="z-10 text-center flex flex-col items-center">
          <MonitorPlay className="w-24 h-24 text-blue-500 mb-8 opacity-80" />
          <h1 className="text-6xl font-bold tracking-tight mb-6 bg-gradient-to-r from-blue-400 to-indigo-400 text-transparent bg-clip-text">
            Smart Classroom Ready
          </h1>
          <p className="text-2xl text-slate-400 max-w-2xl font-light">
            Waiting for faculty to start the lecture. The attendance QR code will appear here automatically.
          </p>
          
          <div className="mt-16 text-slate-500 font-mono text-xl">
            {new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
          </div>
        </div>
      </div>
    )
  }

  // ACTIVE STATE: Lecture is running
  const qrPayload = JSON.stringify({
    sessionId: session.id,
    token: currentToken
  })

  return (
    <div className="min-h-screen bg-white flex">
      {/* Left side: Information (1/3 width) */}
      <div className="w-1/3 bg-slate-950 text-white flex flex-col justify-between p-12 border-r border-slate-800">
        <div>
          <div className="flex items-center gap-3 text-blue-400 font-bold text-2xl tracking-tight mb-16">
            <div className="bg-blue-500 text-white p-2 rounded-lg">
              <MonitorPlay size={28} />
            </div>
            <span>Attendify Projector</span>
          </div>
          
          <div className="space-y-8 animate-in slide-in-from-left-8 duration-700">
            <div>
              <p className="text-slate-500 uppercase tracking-widest text-sm font-semibold mb-2">Current Lecture</p>
              <h2 className="text-5xl font-bold leading-tight">{session.subject_name}</h2>
            </div>
            
            <div>
              <p className="text-slate-500 uppercase tracking-widest text-sm font-semibold mb-2">Faculty</p>
              <h3 className="text-3xl text-slate-300 font-light">{session.faculty_name}</h3>
            </div>
          </div>
        </div>

        <div className="bg-slate-900/50 p-6 rounded-2xl border border-slate-800">
          <h4 className="text-lg font-semibold text-white mb-2">How to mark attendance:</h4>
          <ol className="text-slate-400 space-y-2 text-lg">
            <li>1. Open the Attendify mobile app.</li>
            <li>2. Go to the "Scan QR" section.</li>
            <li>3. Point your camera at this screen.</li>
          </ol>
          <div className="mt-6 flex items-center gap-3 text-sm text-amber-400/80 bg-amber-400/10 p-3 rounded-lg">
            <span className="relative flex h-3 w-3">
              <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-amber-400 opacity-75"></span>
              <span className="relative inline-flex rounded-full h-3 w-3 bg-amber-500"></span>
            </span>
            Security Geofencing is active.
          </div>
        </div>
      </div>

      {/* Right side: Giant QR Code (2/3 width) */}
      <div className="w-2/3 flex flex-col items-center justify-center p-12 bg-slate-50 relative">
        <div className="bg-white p-12 rounded-[3rem] shadow-2xl border border-slate-100 flex flex-col items-center animate-in zoom-in-95 duration-500">
          <QRCodeSVG 
            value={qrPayload} 
            size={600}
            level="H"
            includeMargin={false}
          />
          
          {/* Progress Bar Container */}
          <div className="w-full mt-12 bg-slate-100 h-2 rounded-full overflow-hidden">
            <div 
              className="h-full bg-blue-500 transition-all duration-1000 ease-linear"
              style={{ width: `${progressPercent}%` }}
            />
          </div>
          <p className="text-slate-400 mt-4 font-mono text-lg text-center">Code rotates securely every 10 seconds</p>
        </div>
      </div>
    </div>
  )
}
