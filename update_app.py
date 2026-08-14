import os
import re

file_path = r"c:\Attendance-system\src\App.tsx"
with open(file_path, "r", encoding="utf-8") as f:
    content = f.read()

# 1. Add import Settings from './pages/Settings'
if "import Settings from './pages/Settings'" not in content:
    content = content.replace("import Scanner from './pages/student/Scanner'", "import Scanner from './pages/student/Scanner'\nimport Settings from './pages/Settings'")

# 2. Add route
if "<Route path=\"settings\" element={<Settings />} />" not in content:
    content = content.replace("<Route path=\"scanner\" element={<Scanner />} />", "<Route path=\"scanner\" element={<Scanner />} />\n            <Route path=\"settings\" element={<Settings />} />")

with open(file_path, "w", encoding="utf-8") as f:
    f.write(content)

print("Updated App.tsx")
