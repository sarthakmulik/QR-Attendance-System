import { createClient } from '@supabase/supabase-js'

const supabase = createClient(
  'https://bdtdobpbnjuenkvoblsq.supabase.co',
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJkdGRvYnBibmp1ZW5rdm9ibHNxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU4MzI1NDIsImV4cCI6MjEwMTQwODU0Mn0.21yJ7W2QNjLYYV8YQQ4Bz_qzzozfUeaiHK1RL56SV6E'
)

async function debugSQL() {
  const { data, error } = await supabase.rpc('debug_auth_insert', {
    test_email: `test_${Date.now()}@test.com`
  })
  console.log('Result:', data)
  console.log('Error:', error)
}

debugSQL()
