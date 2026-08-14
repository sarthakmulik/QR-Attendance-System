import http.server
import socketserver
import os
import threading
import time

class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Content-Disposition', 'attachment; filename="Attendance_System_Pitch.pptx"')
        super().end_headers()

os.chdir(r'c:\Attendance-system')
httpd = socketserver.TCPServer(('', 8000), Handler)
threading.Thread(target=httpd.serve_forever, daemon=True).start()
print("Server started on port 8000")
time.sleep(600) # Keep server alive for 10 minutes
