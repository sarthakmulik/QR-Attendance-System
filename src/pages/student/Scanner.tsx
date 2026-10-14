import { useEffect, useState, useRef } from 'react'
import { Html5Qrcode } from 'html5-qrcode'
import { CheckCircle2, XCircle, Loader2, Camera, AlertTriangle } from 'lucide-react'
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { supabase } from '@/lib/supabase'

export default function Scanner() {
  const [scanResult, setScanResult] = useState<{ success: boolean; message: string } | null>(null)
  const [isProcessing, setIsProcessing] = useState(false)
  const [hasCameraPermission, setHasCameraPermission] = useState<boolean | null>(null)
  
  const scannerRef = useRef<Html5Qrcode | null>(null)
  const isComponentMounted = useRef(true)
  // Ref (not state) so the 10fps QR callback sees the guard immediately,
  // before any re-render — prevents duplicate mark_attendance RPC calls.
  const isProcessingRef = useRef(false)

  useEffect(() => {
    isComponentMounted.current = true
    
    // We only want to start the scanner if we are not currently showing a result
    if (!scanResult && !isProcessing) {
      startScanner()
    }

    return () => {
      isComponentMounted.current = false
      stopScanner()
    }
  }, [scanResult, isProcessing])

  const stopScanner = async () => {
    if (scannerRef.current) {
      try {
        if (scannerRef.current.isScanning) {
          await scannerRef.current.stop()
        }
        scannerRef.current.clear()
        scannerRef.current = null
      } catch (err) {
        console.error("Failed to stop scanner:", err)
      }
    }
  }

  const startScanner = async () => {
    try {
      // Clean up any existing instance first
      await stopScanner()

      // The raw Html5Qrcode is much more reliable for mobile than Html5QrcodeScanner
      const html5QrCode = new Html5Qrcode("qr-reader")
      scannerRef.current = html5QrCode
      
      await html5QrCode.start(
        { facingMode: "environment" }, // Force back camera for mobile!
        {
          fps: 10,
          qrbox: { width: 250, height: 250 },
          aspectRatio: 1.0,
        },
        onScanSuccess,
        onScanFailure
      )
      
      if (isComponentMounted.current) {
        setHasCameraPermission(true)
      }
    } catch (err) {
      console.error("Camera startup error:", err)
      if (isComponentMounted.current) {
        setHasCameraPermission(false)
      }
    }
  }

  const resetProcessing = () => {
    isProcessingRef.current = false
    if (isComponentMounted.current) {
      setIsProcessing(false)
    }
  }

  const onScanSuccess = async (decodedText: string) => {
    try {
      if (isProcessingRef.current) return
      isProcessingRef.current = true
      setIsProcessing(true)
      await stopScanner() // Stop camera immediately to freeze frame and save battery

      const payload = JSON.parse(decodedText)
      
      if (!payload.sessionId || !payload.token) {
        throw new Error("Invalid QR Code format. Please scan the official Attendify QR.")
      }

      // Generate robust device fingerprint for anti-proxy
      let deviceToken = localStorage.getItem('attendify_device_token')
      if (!deviceToken) {
        deviceToken = Math.random().toString(36).substring(2) + Date.now().toString(36)
        localStorage.setItem('attendify_device_token', deviceToken)
      }
      
      // Collect available hardware data silently
      const hardwareConcurrency = navigator.hardwareConcurrency || 'unknown'
      const screenResolution = `${window.screen.width}x${window.screen.height}`
      const colorDepth = window.screen.colorDepth
      const deviceInfo = `${deviceToken}|${navigator.userAgent}|${screenResolution}|${colorDepth}|${hardwareConcurrency}`

      // Function to actually hit the database with location data
      const executeMarkAttendance = async (lat: number | null, lng: number | null) => {
        try {
          const { data, error } = await supabase.rpc('mark_attendance', {
            p_session_id: payload.sessionId,
            p_token: payload.token,
            p_device_info: deviceInfo,
            p_lat: lat,
            p_lng: lng
          })

          if (error) throw error

          if (isComponentMounted.current) {
            setScanResult({
              success: data.success,
              message: data.message
            })
          }
        } catch (err: any) {
          if (isComponentMounted.current) {
            setScanResult({
              success: false,
              message: err.message || "Failed to contact server. Please try again."
            })
          }
        } finally {
          resetProcessing()
        }
      }

      // Geofencing Check
      if ('geolocation' in navigator) {
        navigator.geolocation.getCurrentPosition(
          (position) => {
            // Check GPS accuracy (Must be within 200 meters accuracy to prevent spoofing)
            if (position.coords.accuracy > 200) {
              if (isComponentMounted.current) {
                setScanResult({
                  success: false,
                  message: "GPS accuracy is too low. Please step outside or connect to Wi-Fi to improve location accuracy."
                })
              }
              resetProcessing()
              return
            }
            executeMarkAttendance(position.coords.latitude, position.coords.longitude)
          },
          (error) => {
            let errorMsg = "Failed to get GPS location. Ensure your GPS is enabled."
            if (error.code === error.PERMISSION_DENIED) {
              errorMsg = "Location permission denied. You MUST allow GPS access to mark attendance."
            }
            
            if (isComponentMounted.current) {
              setScanResult({
                success: false,
                message: errorMsg
              })
            }
            resetProcessing()
          },
          // Force high accuracy
          { enableHighAccuracy: true, timeout: 10000, maximumAge: 0 }
        )
      } else {
        if (isComponentMounted.current) {
          setScanResult({
            success: false,
            message: "Geolocation is not supported by your browser."
          })
        }
        resetProcessing()
      }

    } catch (err: any) {
      if (isComponentMounted.current) {
        setScanResult({
          success: false,
          message: err.message || "Failed to process QR code. Please try again."
        })
      }
      resetProcessing()
    }
  }

  const onScanFailure = () => {
    // We intentionally do nothing on failure. The scanner runs at 10fps and will fail continuously until it finds a valid code.
  }

  const resetScanner = () => {
    setScanResult(null)
  }

  return (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500 max-w-md mx-auto md:mt-4 w-full">
      <div className="text-center">
        <h1 className="text-2xl font-bold text-slate-900 dark:text-white tracking-tight">Mark Attendance</h1>
        <p className="text-slate-500 text-sm mt-1">Scan the QR code displayed by your professor.</p>
      </div>

      <Card className="border-none shadow-md overflow-hidden bg-white dark:bg-slate-950 w-full">
        {scanResult ? (
          <CardContent className="p-8 flex flex-col items-center justify-center text-center space-y-4">
            {scanResult.success ? (
              <div className="bg-green-100 dark:bg-green-900/30 p-4 rounded-full text-green-600 dark:text-green-400 mb-2 animate-in zoom-in">
                <CheckCircle2 size={64} />
              </div>
            ) : (
              <div className="bg-red-100 dark:bg-red-900/30 p-4 rounded-full text-red-600 dark:text-red-400 mb-2 animate-in zoom-in">
                <XCircle size={64} />
              </div>
            )}
            
            <CardTitle className={scanResult.success ? "text-green-700 dark:text-green-400" : "text-red-700 dark:text-red-400"}>
              {scanResult.success ? "Attendance Recorded!" : "Scan Failed"}
            </CardTitle>
            
            <p className="text-slate-600 dark:text-slate-300 font-medium">
              {scanResult.message}
            </p>
            
            <Button onClick={resetScanner} className="mt-6 w-full" variant={scanResult.success ? "default" : "destructive"}>
              Scan Another Code
            </Button>
          </CardContent>
        ) : (
          <>
            <CardHeader className="bg-slate-50 dark:bg-slate-900 border-b border-slate-100 dark:border-slate-800 p-4">
              <div className="flex items-center justify-center gap-2 text-primary font-semibold">
                <Camera size={18} />
                Scanner Active
              </div>
            </CardHeader>
            <CardContent className="p-0 relative bg-black min-h-[300px] flex items-center justify-center w-full">
              {isProcessing && (
                <div className="absolute inset-0 z-20 bg-black/80 flex flex-col items-center justify-center text-white backdrop-blur-sm">
                  <Loader2 className="w-12 h-12 animate-spin mb-4 text-primary" />
                  <p className="font-semibold text-lg animate-pulse mb-2">Verifying Security...</p>
                  <p className="text-xs text-slate-400">Checking Geolocation & Device ID</p>
                </div>
              )}
              
              {hasCameraPermission === false && (
                <div className="absolute inset-0 z-10 bg-slate-900 flex flex-col items-center justify-center text-white p-6 text-center">
                  <AlertTriangle className="w-12 h-12 text-amber-500 mb-4" />
                  <p className="font-semibold text-lg mb-2">Camera Access Denied</p>
                  <p className="text-sm text-slate-400 mb-6">You must allow camera permissions in your browser settings to scan QR codes.</p>
                  <Button onClick={startScanner} variant="outline" className="text-slate-900">
                    Try Again
                  </Button>
                </div>
              )}
              
              {/* Pure HTML5QRcode div (no bloated UI library) */}
              <div id="qr-reader" className="w-full bg-black overflow-hidden" style={{ minHeight: '300px' }}></div>
            </CardContent>
          </>
        )}
      </Card>
      
      {!scanResult && (
        <div className="text-center text-xs text-slate-400 bg-slate-50 dark:bg-slate-900/50 p-4 rounded-lg border border-slate-200 dark:border-slate-800">
          <p className="font-medium text-slate-600 dark:text-slate-300 mb-1">Security Notice</p>
          <p>Your device signature and exact GPS coordinates are recorded to prevent proxy attendance.</p>
        </div>
      )}
    </div>
  )
}
