import os

file_path = r"c:\Attendance-system\src\pages\admin\Users.tsx"

with open(file_path, "r", encoding="utf-8") as f:
    content = f.read()

# 1. Update Imports
content = content.replace(
    "import { useUsers, useColleges, useDepartments } from '@/hooks/queries'",
    "import { useUserHierarchy, useColleges, useDepartments } from '@/hooks/queries'\nimport { UserTreeView } from '@/components/users/UserTreeView'"
)

# 2. Update Hooks
content = content.replace(
    "const { data: users, isLoading } = useUsers()",
    "const { data: hierarchy, isLoading } = useUserHierarchy()"
)

# 3. Handle loading state explicitly since users is now hierarchy
content = content.replace(
    "const filteredUsers = users?.filter(user => {",
    "// We skip flat filtering when using the tree view\n  const filteredUsers = [];\n  const skipOldFiltering = true;\n  const old_filter = (user: any) => {"
)

# 4. Replace the Table UI with UserTreeView
# We need to find the `<Card className="border-none shadow-sm overflow-hidden">` that wraps the table.
# And replace it down to `</Card>`.
table_start = content.find('<Card className="border-none shadow-sm overflow-hidden">')
table_end = content.find('</Card>', table_start) + len('</Card>')

new_ui = """
      {/* Search and Filters are hidden for Tree View for now, but can be added back */}
      {hierarchy ? (
        <UserTreeView 
          hierarchy={hierarchy} 
          userRole={userRole} 
          onEditRole={(user) => {
            setEditingUser(user)
            editForm.reset({ role: user.role, department_id: user.departments?.id || null })
            setIsEditDialogOpen(true)
          }} 
        />
      ) : (
        <div className="flex items-center justify-center p-8 text-slate-500">No data available</div>
      )}
"""

content = content[:table_start] + new_ui + content[table_end:]

# 5. Fix queryClient invalidation
content = content.replace(
    "queryClient.invalidateQueries({ queryKey: ['users'] })",
    "queryClient.invalidateQueries({ queryKey: ['user-hierarchy'] })"
)

with open(file_path, "w", encoding="utf-8") as f:
    f.write(content)

print("Updated Users.tsx to use Tree View")
