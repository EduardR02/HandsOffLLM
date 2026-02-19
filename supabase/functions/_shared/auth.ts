import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

export const DISABLE_USAGE_TRACKING =
  (Deno.env.get('DISABLE_USAGE_TRACKING') ?? 'false').toLowerCase() === 'true'

export function createSupabaseClients(authHeader: string | null) {
  const supabaseUrl = Deno.env.get('SUPABASE_URL')!
  const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')!
  const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')

  const supabaseAuth = createClient(supabaseUrl, supabaseAnonKey, {
    global: {
      headers: authHeader ? { Authorization: authHeader } : {}
    }
  })

  const supabaseAdmin = (!DISABLE_USAGE_TRACKING && supabaseServiceKey)
    ? createClient(supabaseUrl, supabaseServiceKey)
    : null

  return { supabaseAuth, supabaseAdmin }
}

export async function validateJwt(supabaseAuth: any): Promise<{ user: any | null; response: Response | null }> {
  const { data: { user }, error: authError } = await supabaseAuth.auth.getUser()

  if (authError || !user) {
    return {
      user: null,
      response: new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' }
      })
    }
  }

  return { user, response: null }
}

export async function checkUserQuota(supabaseAdmin: any, userId: string): Promise<Response | null> {
  if (DISABLE_USAGE_TRACKING || !supabaseAdmin) {
    return null
  }

  const { data: quotaData, error: quotaError } = await supabaseAdmin.rpc('check_user_quota', {
    p_user_id: userId
  })

  if (quotaError) {
    console.error('Quota check failed:', quotaError)
    return new Response(JSON.stringify({ error: 'Failed to check usage quota' }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' }
    })
  }

  const quota = quotaData?.[0]
  if (quota?.quota_exceeded) {
    return new Response(JSON.stringify({
      error: 'Monthly usage limit exceeded',
      current_usage: quota.current_usage,
      limit: quota.monthly_limit
    }), {
      status: 429,
      headers: { 'Content-Type': 'application/json' }
    })
  }

  return null
}

export interface UsageLogInsert {
  user_id: string
  provider: string
  model: string
  cached_input_tokens: number
  input_tokens: number
  reasoning_output_tokens: number
  output_tokens: number
  cost_usd: number
}

export async function insertUsageLog(supabaseAdmin: any, record: UsageLogInsert): Promise<any> {
  if (DISABLE_USAGE_TRACKING || !supabaseAdmin) {
    return null
  }

  const { error } = await supabaseAdmin.from('usage_logs').insert(record)
  return error
}
