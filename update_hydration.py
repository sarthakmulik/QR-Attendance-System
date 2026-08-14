import os

file_path = r"c:\Attendance-system\src\pages\admin\Departments.tsx"
with open(file_path, "r", encoding="utf-8") as f:
    content = f.read()

old_block = """                      <div className="flex items-center gap-4" onClick={(e) => e.stopPropagation()}>
                        {userRole !== 'hod' && (
                          <DropdownMenu>
                            <DropdownMenuTrigger asChild>
                              <Button variant="ghost" size="icon" className="text-slate-400 hover:text-slate-600">
                                <MoreVertical size={16} />
                              </Button>
                            </DropdownMenuTrigger>
                            <DropdownMenuContent align="end" className="w-48">
                              <DropdownMenuItem 
                                onClick={() => deleteDepartmentMutation.mutate(dept.id)}
                                className="text-rose-600 focus:text-rose-600 focus:bg-rose-50"
                              >
                                Delete Department
                              </DropdownMenuItem>
                            </DropdownMenuContent>
                          </DropdownMenu>
                        )}
                      </div>
                    </div>
                  </AccordionTrigger>"""

new_block = """                    </div>
                  </AccordionTrigger>

                  {/* Move DropdownMenu OUTSIDE AccordionTrigger to prevent nested <button> hydration errors */}
                  <div className="absolute right-4 top-5 z-10" onClick={(e) => e.stopPropagation()}>
                    {userRole !== 'hod' && (
                      <DropdownMenu>
                        <DropdownMenuTrigger asChild>
                          <Button variant="ghost" size="icon" className="text-slate-400 hover:text-slate-600">
                            <MoreVertical size={16} />
                          </Button>
                        </DropdownMenuTrigger>
                        <DropdownMenuContent align="end" className="w-48">
                          <DropdownMenuItem 
                            onClick={() => deleteDepartmentMutation.mutate(dept.id)}
                            className="text-rose-600 focus:text-rose-600 focus:bg-rose-50"
                          >
                            Delete Department
                          </DropdownMenuItem>
                        </DropdownMenuContent>
                      </DropdownMenu>
                    )}
                  </div>"""

# Wait, I need to make sure AccordionItem has relative class.
# It already has: <AccordionItem key={dept.id} value={dept.id} className="border-none bg-white dark:bg-slate-950 rounded-xl shadow-sm overflow-hidden px-2">
# Need to add 'relative' to it.
content = content.replace('className="border-none bg-white', 'className="relative border-none bg-white')
content = content.replace(old_block, new_block)

with open(file_path, "w", encoding="utf-8") as f:
    f.write(content)

print("Updated Departments.tsx to fix hydration error")
