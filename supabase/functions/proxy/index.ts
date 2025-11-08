// HandsOffLLM API Proxy
// Routes authenticated requests to LLM providers with usage tracking

import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Provider pricing (per 1M tokens, in USD)
const PRICING = {
  openai: {
    'gpt-4o': { input: 2.50, output: 10.00, cached_input: 1.25 },
    'gpt-4o-mini-tts': { input: 0.6, output: 12.00 }, // TTS model
    'gpt-5': { input: 1.25, output: 10.00, cached_input: 0.125 },
    'gpt-5-mini': { input: 0.25, output: 2.00, cached_input: 0.025 },
    'gpt-4.1': { input: 2.00, output: 8.00, cached_input: 0.50 },
  },
  anthropic: {
    'claude-sonnet-4.5': { input: 3.75, output: 15.00, cached_input: 0.30},
    'claude-sonnet-4': { input: 3.75, output: 15.00, cached_input: 0.30},
    'claude-opus-4.1': { input: 18.75, output: 75.00, cached_input: 1.50 },
    'claude-haiku-4.5': { input: 1.25, output: 5.00, cached_input: 0.10 },
  },
  gemini: {
    'gemini-2.0-flash': { input: 0.10, output: 0.40, cached_input: 0.025 },
    'gemini-2.5-flash': { input: 0.3, output: 2.50, cached_input: 0.03 },
    'gemini-2.5-flash-preview': { input: 0.3, output: 2.50, cached_input: 0.03 },
    'gemini-2.5-pro': { input: 1.25, output: 5.00, cached_input: 0.125 },
  },
  xai: {
    'grok-4-fast': { input: 0.20, output: 0.50, cached_input: 0.05 },
    'grok-4': { input: 3.00, output: 15.00, cached_input: 0.75 },
  },
  moonshot: {
    'kimi-k2-0905-preview': { input: 0.60, output: 2.50, cached_input: 0.15 },
    'kimi-k2-0711-preview': { input: 0.60, output: 2.50, cached_input: 0.15 },
    'kimi-k2-turbo-preview': { input: 1.15, output: 8.00, cached_input: 0.15 },
    'kimi-k2-thinking': { input: 0.60, output: 2.50, cached_input: 0.15 },
    'kimi-k2-thinking-turbo': { input: 1.15, output: 8.00, cached_input: 0.15 },
  },
  mistral: {
    'voxtral-mini': { input: 0.002, output: 0.04 }, // Input per minute, output per 1M tokens
  },
  replicate: {
    'kokoro-82m': { per_second: 0.000225 }, // $0.000225 per second
  }
}

const PROVIDER_CONFIG: Record<string, { pricingKey: keyof typeof PRICING; envKey: string }> = {
  openai: { pricingKey: 'openai', envKey: 'OPENAI' },
  claude: { pricingKey: 'anthropic', envKey: 'ANTHROPIC' },
  anthropic: { pricingKey: 'anthropic', envKey: 'ANTHROPIC' },
  gemini: { pricingKey: 'gemini', envKey: 'GEMINI' },
  xai: { pricingKey: 'xai', envKey: 'XAI' },
  'moonshot ai': { pricingKey: 'moonshot', envKey: 'MOONSHOT' },
  mistral: { pricingKey: 'mistral', envKey: 'MISTRAL' },
  replicate: { pricingKey: 'replicate', envKey: 'REPLICATE' },
}

const MODEL_ALIASES: Partial<Record<keyof typeof PRICING, Array<{ regex: RegExp; key: string }>>> = {
  openai: [
    { regex: /^gpt-4o-mini-tts(?:$|[-_])/, key: 'gpt-4o-mini-tts' },
    { regex: /^gpt-4o(?:$|[-_])/, key: 'gpt-4o' },
    { regex: /^chatgpt-4o(?:$|[-_])/, key: 'gpt-4o' },
    { regex: /^o4-mini(?:$|[-_])/, key: 'gpt-4o' },
    { regex: /^gpt-5-mini(?:$|[-_])/, key: 'gpt-5-mini' },
    { regex: /^gpt-5(?:$|[-_])/, key: 'gpt-5' },
    { regex: /^gpt-4\.1-mini(?:$|[-_])/, key: 'gpt-4.1' },
    { regex: /^gpt-4\.1(?:$|[-_])/, key: 'gpt-4.1' },
  ],
  anthropic: [
    { regex: /^claude-sonnet-4-5(?:$|[-_])/, key: 'claude-sonnet-4.5' },
    { regex: /^claude-sonnet-4(?:$|[-_])/, key: 'claude-sonnet-4' },
    { regex: /^claude-opus-4(?:-1)?(?:$|[-_])/, key: 'claude-opus-4.1' },
    { regex: /^claude-haiku-4(?:[-_]5)?(?:$|[-_])/, key: 'claude-haiku-4.5' },
  ],
  gemini: [
    { regex: /^gemini-2\.5-flash-preview(?:$|[-_])/, key: 'gemini-2.5-flash-preview' },
    { regex: /^gemini-2\.5-flash(?:$|[-_])/, key: 'gemini-2.5-flash' },
    { regex: /^gemini-2\.5-pro(?:$|[-_])/, key: 'gemini-2.5-pro' },
    { regex: /^gemini-2\.0-flash(?:$|[-_])/, key: 'gemini-2.0-flash' },
  ],
  xai: [
    { regex: /^grok-4-fast(?:$|[-_])/, key: 'grok-4-fast' },
    { regex: /^grok-4(?:$|[-_])/, key: 'grok-4' },
  ],
  moonshot: [
    { regex: /^kimi-k2-0905-preview(?:$|[-_])/, key: 'kimi-k2-0905-preview' },
    { regex: /^kimi-k2-0711-preview(?:$|[-_])/, key: 'kimi-k2-0711-preview' },
    { regex: /^kimi-k2-turbo-preview(?:$|[-_])/, key: 'kimi-k2-turbo-preview' },
    { regex: /^kimi-k2-thinking-turbo(?:$|[-_])/, key: 'kimi-k2-thinking-turbo' },
    { regex: /^kimi-k2-thinking(?:$|[-_])/, key: 'kimi-k2-thinking' },
  ],
  mistral: [
    { regex: /^voxtral-mini(?:$|[-_])/, key: 'voxtral-mini' },
    { regex: /^voxtral(?:$|[-_])/, key: 'voxtral-mini' },
  ],
}

const DISABLE_USAGE_TRACKING =
  (Deno.env.get('DISABLE_USAGE_TRACKING') ?? 'false').toLowerCase() === 'true'

interface UsageData {
  cached_input_tokens: number
  input_tokens: number
  reasoning_output_tokens: number
  output_tokens: number
  cost_usd: number
  prompt_seconds?: number
}

serve(async (req) => {
  // CORS headers
  if (req.method === 'OPTIONS') {
    return new Response(null, {
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
        'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
      }
    })
  }

  try {
    // Initialize Supabase clients once (reuse across requests via module cache)
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')!
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
    const authHeader = req.headers.get('Authorization')!

    const supabaseAuth = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } }
    })

    // Create admin client for database writes (bypasses RLS)
    const supabaseAdmin = (!DISABLE_USAGE_TRACKING && supabaseServiceKey)
      ? createClient(supabaseUrl, supabaseServiceKey)
      : null

    // Validate JWT and get user
    const { data: { user }, error: authError } = await supabaseAuth.auth.getUser()
    if (authError || !user) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' }
      })
    }

    // Check quota using optimized combined query
    if (!DISABLE_USAGE_TRACKING && supabaseAdmin) {
      const { data: quotaData, error: quotaError } = await supabaseAdmin.rpc('check_user_quota', {
        p_user_id: user.id
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
    }

    // Parse request body
    const body = await req.json()
    const { provider, method, headers, bodyData } = body
    let endpoint: string = body.endpoint

    const providerId = (provider || '').toLowerCase()
    const providerConfig = PROVIDER_CONFIG[providerId]
    if (!providerConfig) {
      return new Response(JSON.stringify({
        error: `Unsupported provider: ${provider}`
      }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' }
      })
    }

    const pricingProvider = providerConfig.pricingKey

    // Get API key for provider
    const apiKey = Deno.env.get(`${providerConfig.envKey}_API_KEY`)
    if (!apiKey) {
      return new Response(JSON.stringify({
        error: `API key not configured for provider: ${providerConfig.envKey.toLowerCase()}`
      }), {
        status: 500,
        headers: { 'Content-Type': 'application/json' }
      })
    }

    // Inject API key into headers
    const providerHeaders = { ...headers }

    if (pricingProvider === 'openai' || pricingProvider === 'xai' || pricingProvider === 'moonshot' || pricingProvider === 'mistral' || pricingProvider === 'replicate') {
      providerHeaders['Authorization'] = `Bearer ${apiKey}`
    } else if (pricingProvider === 'anthropic') {
      providerHeaders['x-api-key'] = apiKey
    } else if (pricingProvider === 'gemini') {
      try {
        const url = new URL(endpoint)
        url.searchParams.set('key', apiKey)
        if (!url.searchParams.has('alt')) {
          url.searchParams.set('alt', 'sse')
        }
        endpoint = url.toString()
      } catch (err) {
        console.error('Failed to append Gemini API key to endpoint:', err)
        return new Response(JSON.stringify({ error: 'Invalid Gemini endpoint URL' }), {
          status: 400,
          headers: { 'Content-Type': 'application/json' }
        })
      }
    }

    // Detect TTS and transcription endpoints early
    const isTTS = endpoint.includes('/audio/speech') || endpoint.includes('/predictions')
    const isReplicate = endpoint.includes('api.replicate.com')
    const isTranscription = endpoint.includes('/audio/transcriptions')

    // Handle transcription with base64 audio
    let requestBody: BodyInit | undefined
    if (isTranscription && bodyData?.audio_base64) {
      // Decode base64 audio and create multipart form using FormData
      const audioBase64 = bodyData.audio_base64
      const audioBytes = Uint8Array.from(atob(audioBase64), c => c.charCodeAt(0))

      const filename = bodyData.filename || 'audio.wav'
      const contentType = bodyData.content_type || 'audio/wav'
      const model = bodyData.model || 'voxtral-mini-latest'

      // Use FormData for proper multipart/form-data encoding
      const formData = new FormData()
      const audioBlob = new Blob([audioBytes], { type: contentType })
      formData.append('file', audioBlob, filename)
      formData.append('model', model)

      // Remove Content-Type from headers - FormData sets it automatically with correct boundary
      delete providerHeaders['Content-Type']
      requestBody = formData
      console.log(`🎤 Transcription request: ${audioBytes.length} bytes audio, model: ${model}, filename: ${filename}`)
    } else {
      requestBody = bodyData ? JSON.stringify(bodyData) : undefined
    }

    // Forward request to provider
    const response = await fetch(endpoint, {
      method: method || 'POST',
      headers: providerHeaders,
      body: requestBody
    })

    if (!response.ok) {
      const errorText = await response.text()
      return new Response(errorText, {
        status: response.status,
        headers: { 'Content-Type': response.headers.get('Content-Type') || 'text/plain' }
      })
    }

    // Extract model name (already set for transcription with base64)
    let model = bodyData?.model || 'unknown'

    // Gemini includes model in URL path, not body
    if (pricingProvider === 'gemini' && endpoint.includes('/models/')) {
      const modelMatch = endpoint.match(/\/models\/([^:?]+)/)
      if (modelMatch) {
        model = modelMatch[1]
      }
    }

    // Replicate uses 'version' field to identify model, use kokoro-82m as model name
    if (pricingProvider === 'replicate') {
      model = 'kokoro-82m'
    }

    // Debug log for model extraction
    if (model === 'unknown') {
      console.warn(`⚠️ Model extraction failed for ${pricingProvider}. Endpoint: ${endpoint}, bodyData:`, JSON.stringify(bodyData).substring(0, 200))
    }

    // Handle non-streaming responses (Mistral transcription)
    if (isTranscription && pricingProvider === 'mistral') {
      const responseData = await response.arrayBuffer()
      const jsonText = new TextDecoder().decode(responseData)
      const jsonData = JSON.parse(jsonText)

      // Extract usage from Mistral transcription response
      const usage = jsonData.usage
      if (usage) {
        const promptSeconds = usage.prompt_audio_seconds || 0
        const outputTokens = usage.completion_tokens || 0

        const usageData: UsageData = {
          cached_input_tokens: 0,
          input_tokens: 0,
          reasoning_output_tokens: 0,
          output_tokens: outputTokens,
          cost_usd: 0,
          prompt_seconds: promptSeconds
        }

        const cost = calculateCost(pricingProvider, model, usageData)

        if (!DISABLE_USAGE_TRACKING && supabaseAdmin) {
          await supabaseAdmin.from('usage_logs').insert({
            user_id: user.id,
            provider: pricingProvider,
            model,
            cached_input_tokens: 0,
            input_tokens: 0,
            reasoning_output_tokens: 0,
            output_tokens: outputTokens,
            cost_usd: cost
          })

          console.log(`🎤 Mistral transcription logged: ${promptSeconds}s audio, ${outputTokens} tokens - $${cost.toFixed(6)}`)
        }
      }

      // Return the response to client
      return new Response(responseData, {
        headers: {
          'Content-Type': response.headers.get('Content-Type') || 'application/json'
        }
      })
    }

    // Stream response back to client while capturing usage
    let streamingUsage: UsageData | null = null

    const transformedStream = new TransformStream({
      transform(chunk, controller) {
        controller.enqueue(chunk) // Pass through immediately

        // Try to extract usage from this chunk
        try {
          const text = new TextDecoder().decode(chunk)
          const usage = extractUsageFromChunk(text, pricingProvider, streamingUsage)
          if (usage) {
            streamingUsage = usage
          }
        } catch (e) {
          // Ignore parsing errors
        }
      },
      async flush() {
        // Handle special cases for TTS that don't return usage
        if (isTTS && pricingProvider === 'openai') {
          // Estimate OpenAI TTS usage based on input text
          const ttsInputText = bodyData?.input || ''
          const inputTokens = Math.ceil(ttsInputText.length / 4) // ~4 chars per token
          const outputTokens = Math.ceil(inputTokens * 6.25) // Audio tokens = text tokens * 6.25

          streamingUsage = {
            cached_input_tokens: 0,
            input_tokens: inputTokens,
            reasoning_output_tokens: 0,
            output_tokens: outputTokens,
            cost_usd: 0
          }

          console.log(`🎤 TTS usage estimated: ${inputTokens} input tokens → ${outputTokens} audio tokens`)
        } else if (isReplicate && pricingProvider === 'replicate') {
          // Estimate Replicate TTS usage based on input text length
          // Approximate: ~150 words per minute, ~5 chars per word = 750 chars per minute
          const ttsInputText = bodyData?.input?.text || ''
          const estimatedMinutes = Math.max(0.005, ttsInputText.length / 750) // Minimum 0.3 seconds
          const estimatedSeconds = estimatedMinutes * 60

          streamingUsage = {
            cached_input_tokens: 0,
            input_tokens: 0,
            reasoning_output_tokens: 0,
            output_tokens: 0,
            cost_usd: 0,
            prompt_seconds: estimatedSeconds
          }

          console.log(`🎤 Replicate TTS usage estimated: ${ttsInputText.length} chars → ${estimatedSeconds.toFixed(2)}s audio`)
        }

        // Stream finished, write usage to database
        if (streamingUsage && !DISABLE_USAGE_TRACKING && supabaseAdmin) {
          const cost = calculateCost(pricingProvider, model, streamingUsage)

          const { error: insertError } = await supabaseAdmin.from('usage_logs').insert({
            user_id: user.id,
            provider: pricingProvider,
            model,
            cached_input_tokens: streamingUsage.cached_input_tokens,
            input_tokens: streamingUsage.input_tokens,
            reasoning_output_tokens: streamingUsage.reasoning_output_tokens,
            output_tokens: streamingUsage.output_tokens,
            cost_usd: cost
          })

          if (insertError) {
            console.error('Failed to log usage:', insertError)
          } else {
            console.log(`✅ Logged usage: ${model} - $${cost.toFixed(6)} (user: ${user.id.substring(0, 8)})`)
          }
        } else if (!isTTS && !isTranscription && !DISABLE_USAGE_TRACKING) {
          console.warn(`⚠️ No usage data captured for ${pricingProvider} ${model}`)
        }
      }
    })

    return new Response(
      response.body!.pipeThrough(transformedStream),
      {
        headers: {
          'Content-Type': response.headers.get('Content-Type') || 'text/event-stream',
          'Cache-Control': 'no-cache',
          'Connection': 'keep-alive',
        }
      }
    )

  } catch (error) {
    console.error('Proxy error:', error)
    return new Response(JSON.stringify({
      error: 'Internal server error',
      message: error.message
    }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' }
    })
  }
})

function extractUsageFromChunk(
  text: string,
  provider: keyof typeof PRICING,
  current: UsageData | null
): UsageData | null {
  try {
    // Extract JSON from SSE format
    const lines = text.split('\n')
    for (const line of lines) {
      if (line.startsWith('data: ')) {
        const jsonStr = line.slice(6).trim()
        if (jsonStr === '[DONE]' || !jsonStr) continue

        const parsed = JSON.parse(jsonStr)
        const base: UsageData = current ?? {
          cached_input_tokens: 0,
          input_tokens: 0,
          reasoning_output_tokens: 0,
          output_tokens: 0,
          cost_usd: 0,
          prompt_seconds: 0
        }

        switch (provider) {
          case 'openai':
            if (parsed.type === 'response.completed' && parsed.response?.usage) {
              const usage = parsed.response.usage
              return {
                cached_input_tokens: usage.cached_input_tokens || 0,
                input_tokens: usage.input_tokens || usage.prompt_tokens || 0,
                reasoning_output_tokens:
                  usage.reasoning_tokens ||
                  usage.reasoning_output_tokens ||
                  usage.output_tokens_details?.reasoning_tokens ||
                  0,
                output_tokens: usage.output_tokens || 0,
                cost_usd: 0,
                prompt_seconds: base.prompt_seconds
              }
            }
            break

          case 'anthropic': {
            if (parsed.type === 'message_start' && parsed.message?.usage) {
              const usage = parsed.message.usage
              base.cached_input_tokens =
                (usage.cache_read_input_tokens || 0) +
                (usage.cache_creation_input_tokens || 0)
              base.input_tokens = usage.input_tokens || 0
              base.output_tokens = usage.output_tokens || 0
              return base
            }

            if (parsed.type === 'message_delta' && parsed.usage) {
              base.cached_input_tokens =
                (parsed.usage.cache_read_input_tokens || 0) +
                (parsed.usage.cache_creation_input_tokens || 0)
              base.input_tokens = parsed.usage.input_tokens ?? base.input_tokens
              base.output_tokens = parsed.usage.output_tokens ?? base.output_tokens
              return base
            }
            break
          }

          case 'gemini':
            if (parsed.usageMetadata) {
              return {
                cached_input_tokens: parsed.usageMetadata.cachedContentTokenCount || 0,
                input_tokens: parsed.usageMetadata.promptTokenCount || 0,
                reasoning_output_tokens: parsed.usageMetadata.thoughtsTokenCount || 0,
                output_tokens: parsed.usageMetadata.candidatesTokenCount || 0,
                cost_usd: 0,
                prompt_seconds: base.prompt_seconds
              }
            }
            break

          case 'xai':
            if (parsed.usage && parsed.choices?.length === 0) {
              const usageArray = Array.isArray(parsed.usage)
                ? parsed.usage
                : [parsed.usage]
              const usage =
                usageArray
                  .slice()
                  .reverse()
                  .find((entry: any) => entry && typeof entry === 'object') ?? {}
              const completion = usage.completion_tokens || 0
              const reasoning = usage.completion_tokens_details?.reasoning_tokens || 0
              return {
                cached_input_tokens:
                  usage.prompt_tokens_details?.cached_tokens || 0,
                input_tokens: usage.prompt_tokens || 0,
                reasoning_output_tokens: reasoning,
                output_tokens: Math.max(0, completion - reasoning),
                cost_usd: 0,
                prompt_seconds: base.prompt_seconds
              }
            }
            break

          case 'moonshot':
            if (parsed.usage && parsed.choices?.length === 0) {
              const usage = parsed.usage
              const completion = usage.completion_tokens || 0
              const reasoning = usage.completion_tokens_details?.reasoning_tokens || 0
              return {
                cached_input_tokens:
                  usage.prompt_tokens_details?.cached_tokens || 0,
                input_tokens: usage.prompt_tokens || 0,
                reasoning_output_tokens: reasoning,
                output_tokens: Math.max(0, completion - reasoning),
                cost_usd: 0,
                prompt_seconds: base.prompt_seconds
              }
            }
            break

          case 'mistral':
            if (parsed.usage) {
              return {
                cached_input_tokens: 0,
                input_tokens: parsed.usage.prompt_tokens || 0,
                reasoning_output_tokens: 0,
                output_tokens: parsed.usage.completion_tokens || 0,
                cost_usd: 0,
                prompt_seconds: parsed.usage.prompt_audio_seconds ?? base.prompt_seconds
              }
            }
            break
        }
      }
    }
    // Fallback: attempt to parse entire chunk as JSON (non-SSE responses)
    const trimmed = text.trim()
    if (trimmed.startsWith('{')) {
      const parsed = JSON.parse(trimmed)

      switch (provider) {
        case 'openai':
          if (parsed.usage) {
            const usage = parsed.usage
            return {
              cached_input_tokens: usage.cached_input_tokens || 0,
              input_tokens: usage.input_tokens || usage.prompt_tokens || 0,
              reasoning_output_tokens:
                usage.reasoning_tokens ||
                usage.reasoning_output_tokens ||
                usage.output_tokens_details?.reasoning_tokens ||
                0,
              output_tokens: usage.output_tokens || usage.completion_tokens || 0,
              cost_usd: 0,
              prompt_seconds: current?.prompt_seconds ?? 0
            }
          }
          break
        case 'anthropic':
          if (parsed.usage) {
            return {
              cached_input_tokens:
                (parsed.usage.cache_read_input_tokens || 0) +
                (parsed.usage.cache_creation_input_tokens || 0),
              input_tokens:
                parsed.usage.input_tokens ||
                (parsed.usage.prompt_tokens ?? 0),
              reasoning_output_tokens: 0,
              output_tokens: parsed.usage.output_tokens || 0,
              cost_usd: 0,
              prompt_seconds: current?.prompt_seconds ?? 0
            }
          }
          break
        case 'gemini':
          if (parsed.usageMetadata) {
            return {
              cached_input_tokens: parsed.usageMetadata.cachedContentTokenCount || 0,
              input_tokens: parsed.usageMetadata.promptTokenCount || 0,
              reasoning_output_tokens: parsed.usageMetadata.thoughtsTokenCount || 0,
              output_tokens: parsed.usageMetadata.candidatesTokenCount || 0,
              cost_usd: 0,
              prompt_seconds: current?.prompt_seconds ?? 0
            }
          }
          break
        case 'xai':
          if (parsed.usage) {
            const usageArray = Array.isArray(parsed.usage)
              ? parsed.usage
              : [parsed.usage]
            const usage =
              usageArray
                .slice()
                .reverse()
                .find((entry: any) => entry && typeof entry === 'object') ?? {}
            const completion = usage.completion_tokens || 0
            const reasoning =
              usage.completion_tokens_details?.reasoning_tokens || 0
            return {
              cached_input_tokens:
                usage.prompt_tokens_details?.cached_tokens || 0,
              input_tokens: usage.prompt_tokens || 0,
              reasoning_output_tokens: reasoning,
              output_tokens: Math.max(0, completion - reasoning),
              cost_usd: 0,
              prompt_seconds: current?.prompt_seconds ?? 0
            }
          }
          break
        case 'moonshot':
          if (parsed.usage) {
            const usage = parsed.usage
            const completion = usage.completion_tokens || 0
            const reasoning =
              usage.completion_tokens_details?.reasoning_tokens || 0
            return {
              cached_input_tokens:
                usage.prompt_tokens_details?.cached_tokens || 0,
              input_tokens: usage.prompt_tokens || 0,
              reasoning_output_tokens: reasoning,
              output_tokens: Math.max(0, completion - reasoning),
              cost_usd: 0,
              prompt_seconds: current?.prompt_seconds ?? 0
            }
          }
          break
        case 'mistral':
          if (parsed.usage) {
            return {
              cached_input_tokens: 0,
              input_tokens: parsed.usage.prompt_tokens || 0,
              reasoning_output_tokens: 0,
              output_tokens: parsed.usage.completion_tokens || 0,
              cost_usd: 0,
              prompt_seconds: parsed.usage.prompt_audio_seconds ?? current?.prompt_seconds ?? 0
            }
          }
          break
      }
    }
  } catch (e) {
    // Ignore parsing errors
  }

  return null
}

function calculateCost(provider: keyof typeof PRICING, model: string, usage: UsageData): number {
  const providerPricing = PRICING[provider]
  if (!providerPricing) return 0

  const normalizedModel = model.toLowerCase()

  let modelPricing: any = null

  // Direct match first (case-insensitive)
  for (const [modelKey, pricing] of Object.entries(providerPricing)) {
    if (normalizedModel === modelKey.toLowerCase()) {
      modelPricing = pricing
      break
    }
  }

  // Alias / regex-based matching
  if (!modelPricing) {
    const aliases = MODEL_ALIASES[provider] || []
    for (const { regex, key } of aliases) {
      if (regex.test(normalizedModel) && providerPricing[key]) {
        modelPricing = providerPricing[key]
        break
      }
    }
  }

  // Fallback to longest key contained within the model string
  if (!modelPricing) {
    const sortedKeys = Object.keys(providerPricing).sort((a, b) => b.length - a.length)
    for (const key of sortedKeys) {
      if (normalizedModel.includes(key.toLowerCase())) {
        modelPricing = providerPricing[key]
        break
      }
    }
  }

  if (!modelPricing) return 0

  if (provider === 'mistral') {
    const minutes = (usage.prompt_seconds || 0) / 60
    const perMinute = modelPricing.input || 0
    const outputRate = modelPricing.output || 0
    const minuteCost = minutes * perMinute
    const textCost = (usage.output_tokens / 1_000_000) * outputRate
    return minuteCost + textCost
  }

  if (provider === 'replicate') {
    const seconds = usage.prompt_seconds || 0
    const perSecond = modelPricing.per_second || 0
    return seconds * perSecond
  }

  // Calculate cost (divide by 1M since pricing is per 1M tokens)
  const cachedInputCost = (usage.cached_input_tokens / 1_000_000) * (modelPricing.cached_input || modelPricing.input)
  const inputCost = (usage.input_tokens / 1_000_000) * modelPricing.input
  const reasoningOutputCost = (usage.reasoning_output_tokens / 1_000_000) * (modelPricing.reasoning_output || modelPricing.output)
  const outputCost = (usage.output_tokens / 1_000_000) * modelPricing.output

  return cachedInputCost + inputCost + reasoningOutputCost + outputCost
}
