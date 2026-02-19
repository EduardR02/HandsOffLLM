export const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, prefer',
}

export function handleCorsOptions(req: Request): Response | null {
  if (req.method !== 'OPTIONS') {
    return null
  }

  return new Response(null, { headers: CORS_HEADERS })
}
