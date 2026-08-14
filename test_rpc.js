import { createClient } from '@supabase/supabase-js'

const supabase = createClient(
  'https://bdtdobpbnjuenkvoblsq.supabase.co',
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJkdGRvYnBibmp1ZW5rdm9ibHNxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU4MzI1NDIsImV4cCI6MjEwMTQwODU0Mn0.21yJ7W2QNjLYYV8YQQ4Bz_qzzozfUeaiHK1RL56SV6E'
)

async function getDBError() {
  const { data, error } = await supabase.rpc('get_dashboard_stats')
  console.log(error)
}

getDBError()
