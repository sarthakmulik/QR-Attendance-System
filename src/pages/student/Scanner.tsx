import { useEffect, useState } from 'react'
import { Html5QrcodeScanner, Html5QrcodeScanType } from 'html5-qrcode'
import { CheckCircle2, XCircle, Loader2, Camera } from 'lucide-react'
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { supabase } from '@/lib/supabase'

export default function Scanner() {
  const [scanResult, setScanResult] = useState<{ success: boolean; message: string } | null>(null)
  const [isProcessing, setIsProcessing] = useState(false)
  const [scannerInstance, setScannerInstance] = useState<Html5QrcodeScanner | null>(null)

  useEffect(() => {
    // Only initialize if not already processing a result
    if (!scanResult && !isProcessing && !scannerInstance) {
      const scanner = new Html5QrcodeScanner(
        "qr-reader",
        { 
          fps: 10, 
          qrbox: { width: 250, height: 250 }, 
          aspectRatio: 1.0,
          supportedScanTypes: [Html5QrcodeScanType.SCAN_TYPE_CAMERA]
        },
        /* verbose= */ false
      )
      
      setScannerInstance(scanner)

      scanner.render(onScanSuccess, onScanFailure)

      return () => {
        scanner.clear().catch(console.error)
      }
    }
  }, [scanResult, isProcessing])

  const onScanSuccess = async (decodedText: string) => {
    try {
      // Pause scanner while processing
      if (scannerInstance) {
        scannerInstance.pause(true)
      }
      setIsProcessing(true)

      const payload = JSON.parse(decodedText)
      
      if (!payload.sessionId || !payload.token) {
        throw new Error("Invalid QR Code format")
      }

      // Generate robust device fingerprint
      let deviceToken = localStorage.getItem('attendify_device_token')
      if (!deviceToken) {
        deviceToken = Math.random().toString(36).substring(2) + Date.now().toString(36)
        localStorage.setItem('attendify_device_token', deviceToken)
      }
      const hardwareConcurrency = navigator.hardwareConcurrency || 'unknown'
      const screenResolution = `${window.screen.width}x${window.screen.height}`
      const colorDepth = window.screen.colorDepth
      
      const deviceInfo = `${deviceToken}|${navigator.userAgent}|${screenResolution}|${colorDepth}|${hardwareConcurrency}`

      const markPresent = async (lat: number | null, lng: number | null) => {
        try {
          const { data, error } = await supabase.rpc('mark_attendance', {
            p_session_id: payload.sessionId,
            p_token: payload.token,
            p_device_info: deviceInfo,
            p_lat: lat,
            p_lng: lng
          })

          if (error) throw error

          setScanResult({
            success: data.success,
            message: data.message
          })
        } catch (err: any) {
          setScanResult({
            success: false,
            message: err.message || "Failed to process QR code. Please try again."
          })
        } finally {
          setIsProcessing(false)
          if (scannerInstance) {
            scannerInstance.clear()
            setScannerInstance(null)
          }
        }
      }

      if ('geolocation' in navigator) {
        navigator.geolocation.getCurrentPosition(
          (position) => {
            if (position.coords.accuracy > 200) {
              setScanResult({
                success: false,
                message: "GPS accuracy is too low. Please step outside or connect to Wi-Fi to improve location accuracy."
              })
              setIsProcessing(false)
              if (scannerInstance) {
                scannerInstance.clear()
                setScannerInstance(null)
              }
              return
            }
            markPresent(position.coords.latitude, position.coords.longitude)
          },
          (error) => {
            setScanResult({
              success: false,
              message: error.code === error.PERMISSION_DENIED 
                ? "Location permission denied. You must allow GPS access to mark attendance."
                : "Failed to get GPS location. Ensure your GPS is enabled."
            })
            setIsProcessing(false)
            if (scannerInstance) {
              scannerInstance.clear()
              setScannerInstance(null)
            }
          },
          { enableHighAccuracy: true, timeout: 10000, maximumAge: 0 }
        )
      } else {
        setScanResult({
          success: false,
          message: "Geolocation is not supported by your browser."
        })
        setIsProcessing(false)
        if (scannerInstance) {
          scannerInstance.clear()
          setScannerInstance(null)
        }
      }

    } catch (err: any) {
      setScanResult({
        success: false,
        message: err.message || "Failed to process QR code. Please try again."
      })
      setIsProcessing(false)
      if (scannerInstance) {
        scannerInstance.clear()
        setScannerInstance(null)
      }
    }
  }

  const onScanFailure = (error: any) => {
    // Ignore frequent scan failures (e.g. when pointing at empty space)
    // console.warn(`Code scan error = ${error}`)
  }

  const resetScanner = () => {
    setScanResult(null)
  }

  return (
    <div className="space-y-6 animate-in fade-in slide-in-from-bottom-4 duration-500 max-w-md mx-auto mt-4">
      <div className="text-center">
        <h1 className="text-2xl font-bold text-slate-900 dark:text-white tracking-tight">Mark Attendance</h1>
        <p className="text-slate-500 text-sm mt-1">Scan the QR code displayed by your professor.</p>
      </div>

      <Card className="border-none shadow-md overflow-hidden">
        {scanResult ? (
          <CardContent className="p-8 flex flex-col items-center justify-center text-center space-y-4">
            {scanResult.success ? (
              <div className="bg-green-100 p-4 rounded-full text-green-600 mb-2 animate-in zoom-in">
                <CheckCircle2 size={64} />
              </div>
            ) : (
              <div className="bg-red-100 p-4 rounded-full text-red-600 mb-2 animate-in zoom-in">
                <XCircle size={64} />
              </div>
            )}
            
            <CardTitle className={scanResult.success ? "text-green-700" : "text-red-700"}>
              {scanResult.success ? "Success!" : "Failed"}
            </CardTitle>
            
            <p className="text-slate-600 font-medium">
              {scanResult.message}
            </p>
            
            <Button onClick={resetScanner} className="mt-6 w-full" variant={scanResult.success ? "default" : "destructive"}>
              Scan Again
            </Button>
          </CardContent>
        ) : (
          <>
            <CardHeader className="bg-slate-50 dark:bg-slate-900 border-b border-slate-100 p-4">
              <div className="flex items-center justify-center gap-2 text-primary font-semibold">
                <Camera size={18} />
                Scanner Active
              </div>
            </CardHeader>
            <CardContent className="p-0 relative bg-black min-h-[300px] flex items-center justify-center">
              {isProcessing && (
                <div className="absolute inset-0 z-10 bg-black/60 flex flex-col items-center justify-center text-white">
                  <Loader2 className="w-10 h-10 animate-spin mb-4 text-primary" />
                  <p className="font-medium animate-pulse">Verifying Attendance...</p>
                </div>
              )}
              
              <style>{`
                  #qr-reader {
                    width: 100%;
                    border: none !important;
                  }
                  
                  /* HIDE ALL LINKS (specifically "Scan an Image File") */
                  #qr-reader a {
                    display: none !important;
                  }
                  
                  /* PREMIUM BUTTON STYLING */
                  #qr-reader button {
                    background: linear-gradient(135deg, #4f46e5 0%, #3b82f6 100%) !important;
                    color: white !important;
                    border: none !important;
                    padding: 10px 20px !important;
                    border-radius: 8px !important;
                    font-weight: 600 !important;
                    letter-spacing: 0.5px !important;
                    cursor: pointer !important;
                    margin: 8px 4px !important;
                    transition: all 0.2s ease;
                    box-shadow: 0 4px 6px -1px rgba(79, 70, 229, 0.2) !important;
                  }
                  #qr-reader button:hover {
                    opacity: 0.9 !important;
                    transform: translateY(-1px) !important;
                  }
                  
                  /* TEXT ELEMENTS */
                  #qr-reader span, #qr-reader div {
                    color: #94a3b8 !important;
                    font-family: inherit !important;
                  }
                  
                  /* CAMERA SELECT DROPDOWN */
                  #qr-reader select {
                    background-color: #1e293b !important;
                    color: #f8fafc !important;
                    border: 1px solid #334155 !important;
                    padding: 8px 12px !important;
                    border-radius: 6px !important;
                    margin: 12px 0 !important;
                    font-size: 0.9rem !important;
                    width: 80% !important;
                    max-width: 300px !important;
                    cursor: pointer !important;
                  }
                  
                  /* HIDE REDUNDANT UI ELEMENTS GENERATED BY LIBRARY */
                  #qr-reader__dashboard_section_csr span {
                    display: none !important; 
                  }
              `}</style>
              
              {/* The HTML5 QR Code Scanner injects UI into this div */}
              <div id="qr-reader" className="w-full"></div>
            </CardContent>
          </>
        )}
      </Card>
      
      <div className="text-center text-xs text-slate-400">
        <p>Make sure your camera lens is clean and the screen is bright.</p>
      </div>
    </div>
  )
}
