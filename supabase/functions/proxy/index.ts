// HandsOffLLM API Proxy
// Routes authenticated requests to LLM providers with usage tracking

import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import {
  checkUserQuota,
  createSupabaseClients,
  DISABLE_USAGE_TRACKING,
  insertUsageLog,
  validateJwt,
} from '../_shared/auth.ts'
import { handleCorsOptions } from '../_shared/cors.ts'
import { calculateCost, PRICING } from '../_shared/pricing.ts'

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

interface UsageData {
  cached_input_tokens: number
  input_tokens: number
  reasoning_output_tokens: number
  output_tokens: number
  cost_usd: number
  prompt_seconds?: number
}

const handler = async (req: Request) => {
  const corsResponse = handleCorsOptions(req)
  if (corsResponse) {
    return corsResponse
  }

  try {
    const authHeader = req.headers.get('Authorization')
    const { supabaseAuth, supabaseAdmin } = createSupabaseClients(authHeader)

    const { user, response: authResponse } = await validateJwt(supabaseAuth)
    if (authResponse || !user) {
      return authResponse || new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' }
      })
    }

    const quotaResponse = await checkUserQuota(supabaseAdmin, user.id)
    if (quotaResponse) {
      return quotaResponse
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

    if (pricingProvider === 'replicate') {
      const preferWaitHeader =
        providerHeaders['Prefer'] ||
        providerHeaders['prefer'] ||
        req.headers.get('Prefer') ||
        req.headers.get('prefer')

      if (preferWaitHeader) {
        providerHeaders['Prefer'] = preferWaitHeader
      }

      delete providerHeaders['prefer']
    }

    const requestMethod = (method || 'POST').toUpperCase()

    // Detect TTS and transcription endpoints early
    const isTTS = endpoint.includes('/audio/speech') || endpoint.includes('/predictions')
    const isReplicatePost = shouldLogReplicateUsage(endpoint, requestMethod)
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
      method: requestMethod,
      headers: providerHeaders,
      body: requestBody
    })

    const responseContentType = response.headers.get('Content-Type') || ''

    // 1) Handle provider errors first
    if (!response.ok) {
      const errorText = await response.text()
      return new Response(errorText, {
        status: response.status,
        headers: {
          'Content-Type': pricingProvider === 'replicate'
            ? 'application/json'
            : (responseContentType || 'text/plain')
        }
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

    if (model === 'unknown') {
      console.warn(`⚠️ Model extraction failed for ${pricingProvider}. Endpoint: ${endpoint}, bodyData:`, JSON.stringify(bodyData).substring(0, 200))
    }

    // 2) Handle all non-SSE responses before streaming fallback
    if (!isSSEContentType(responseContentType)) {
      const responseData = await response.arrayBuffer()

      // Mistral transcription returns JSON payload with usage
      if (isTranscription && pricingProvider === 'mistral') {
        const mistralUsage = extractUsageFromChunk(new TextDecoder().decode(responseData), pricingProvider, null)
        if (mistralUsage) {
          await logUsage(supabaseAdmin, user.id, pricingProvider, model, mistralUsage)
          console.log(`🎤 Mistral transcription logged: ${(mistralUsage.prompt_seconds || 0).toFixed(2)}s audio, ${mistralUsage.output_tokens} tokens`)
        }

        return new Response(responseData, {
          status: response.status,
          headers: {
            'Content-Type': responseContentType || 'application/json'
          }
        })
      }

      // Replicate TTS should always return JSON from this endpoint (including 201 pending)
      if (isReplicatePost && pricingProvider === 'replicate') {
        const ttsInputText = bodyData?.input?.text || ''
        const usageData: UsageData = {
          cached_input_tokens: 0,
          input_tokens: 0,
          reasoning_output_tokens: 0,
          output_tokens: 0,
          cost_usd: 0,
          prompt_seconds: estimateReplicateSeconds(ttsInputText)
        }

        await logUsage(supabaseAdmin, user.id, pricingProvider, model, usageData)
        console.log(`🎤 Replicate TTS logged: ${ttsInputText.length} chars → ${(usageData.prompt_seconds || 0).toFixed(2)}s audio`)

        return new Response(responseData, {
          status: response.status,
          headers: {
            'Content-Type': 'application/json'
          }
        })
      }

      let nonStreamingUsage: UsageData | null = null

      // OpenAI TTS is non-SSE audio; estimate token usage for cost accounting
      if (isTTS && pricingProvider === 'openai') {
        const ttsInputText = bodyData?.input || ''
        const inputTokens = Math.ceil(ttsInputText.length / 4)
        const outputTokens = Math.ceil(inputTokens * 6.25)

        nonStreamingUsage = {
          cached_input_tokens: 0,
          input_tokens: inputTokens,
          reasoning_output_tokens: 0,
          output_tokens: outputTokens,
          cost_usd: 0
        }

        console.log(`🎤 TTS usage estimated: ${inputTokens} input tokens → ${outputTokens} audio tokens`)
      } else if (responseContentType.includes('application/json') || responseContentType.includes('text/')) {
        nonStreamingUsage = extractUsageFromChunk(new TextDecoder().decode(responseData), pricingProvider, null)
      }

      if (nonStreamingUsage) {
        await logUsage(supabaseAdmin, user.id, pricingProvider, model, nonStreamingUsage)
      } else if (!isTTS && !isTranscription && !DISABLE_USAGE_TRACKING) {
        console.warn(`⚠️ No usage data captured for ${pricingProvider} ${model}`)
      }

      return new Response(responseData, {
        status: response.status,
        headers: {
          'Content-Type': responseContentType || 'application/json'
        }
      })
    }

    // 3) Stream actual SSE responses while capturing usage
    let streamingUsage: UsageData | null = null
    const streamDecoder = new TextDecoder()

    const transformedStream = new TransformStream({
      transform(chunk, controller) {
        controller.enqueue(chunk)

        try {
          const text = streamDecoder.decode(chunk)
          if (!containsUsageSignal(text)) {
            return
          }

          const usage = extractUsageFromChunk(text, pricingProvider, streamingUsage)
          if (usage) {
            streamingUsage = usage
          }
        } catch (_err) {
          // Ignore parsing errors in individual chunks
        }
      },
      async flush() {
        if (isTTS && pricingProvider === 'openai') {
          const ttsInputText = bodyData?.input || ''
          const inputTokens = Math.ceil(ttsInputText.length / 4)
          const outputTokens = Math.ceil(inputTokens * 6.25)

          streamingUsage = {
            cached_input_tokens: 0,
            input_tokens: inputTokens,
            reasoning_output_tokens: 0,
            output_tokens: outputTokens,
            cost_usd: 0
          }

          console.log(`🎤 TTS usage estimated: ${inputTokens} input tokens → ${outputTokens} audio tokens`)
        } else if (isReplicatePost && pricingProvider === 'replicate') {
          const ttsInputText = bodyData?.input?.text || ''
          const estimatedSeconds = estimateReplicateSeconds(ttsInputText)

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

        if (streamingUsage) {
          await logUsage(supabaseAdmin, user.id, pricingProvider, model, streamingUsage)
        } else if (!isTTS && !isTranscription && !DISABLE_USAGE_TRACKING) {
          console.warn(`⚠️ No usage data captured for ${pricingProvider} ${model}`)
        }
      }
    })

    if (!response.body) {
      return new Response(JSON.stringify({ error: 'Missing SSE response body from provider' }), {
        status: 502,
        headers: { 'Content-Type': 'application/json' }
      })
    }

    return new Response(response.body.pipeThrough(transformedStream), {
      status: response.status,
      headers: {
        'Content-Type': responseContentType || 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
      }
    })

  } catch (error) {
    console.error('Proxy error:', error)
    return new Response(JSON.stringify({
      error: 'Internal server error',
      message: error instanceof Error ? error.message : String(error)
    }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' }
    })
  }
}

if (import.meta.main) {
  serve(handler)
}

export function isSSEContentType(contentType: string): boolean {
  return contentType.toLowerCase().includes('text/event-stream')
}

export function estimateReplicateSeconds(ttsInputText: string): number {
  const estimatedMinutes = Math.max(0.005, ttsInputText.length / 750)
  return estimatedMinutes * 60
}

export function shouldLogReplicateUsage(endpoint: string, method?: string): boolean {
  return endpoint.includes('api.replicate.com') && (method || 'POST').toUpperCase() === 'POST'
}

export function containsUsageSignal(text: string): boolean {
  return text.includes('usage')
}

function mapOpenAIUsage(rawUsage: any, promptSeconds: number): UsageData | null {
  if (!rawUsage || typeof rawUsage !== 'object') {
    return null
  }

  const completionTokens = rawUsage.output_tokens || rawUsage.completion_tokens || 0
  const reasoningTokens =
    rawUsage.reasoning_tokens ||
    rawUsage.reasoning_output_tokens ||
    rawUsage.output_tokens_details?.reasoning_tokens ||
    rawUsage.completion_tokens_details?.reasoning_tokens ||
    0

  return {
    cached_input_tokens:
      rawUsage.cached_input_tokens ||
      rawUsage.prompt_tokens_details?.cached_tokens ||
      0,
    input_tokens: rawUsage.input_tokens || rawUsage.prompt_tokens || 0,
    reasoning_output_tokens: reasoningTokens,
    output_tokens: completionTokens,
    cost_usd: 0,
    prompt_seconds: promptSeconds
  }
}

async function logUsage(
  supabaseAdmin: any,
  userId: string,
  provider: keyof typeof PRICING,
  model: string,
  usage: UsageData
): Promise<void> {
  if (DISABLE_USAGE_TRACKING || !supabaseAdmin) {
    return
  }

  const cost = calculateCost(provider, model, usage)
  const insertError = await insertUsageLog(supabaseAdmin, {
    user_id: userId,
    provider,
    model,
    cached_input_tokens: usage.cached_input_tokens,
    input_tokens: usage.input_tokens,
    reasoning_output_tokens: usage.reasoning_output_tokens,
    output_tokens: usage.output_tokens,
    cost_usd: cost
  })

  if (insertError) {
    console.error('Failed to log usage:', insertError)
    return
  }

  console.log(`✅ Logged usage: ${model} - $${cost.toFixed(6)} (user: ${userId.substring(0, 8)})`)
}

export function extractUsageFromChunk(
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
          case 'openai': {
            const isResponseUsageEvent =
              parsed.type === 'response.completed' ||
              parsed.type === 'response.incomplete' ||
              parsed.type === 'response.failed'

            const openaiUsage =
              (isResponseUsageEvent ? parsed.response?.usage : null) ||
              parsed.response?.usage ||
              parsed.usage

            const mapped = mapOpenAIUsage(openaiUsage, base.prompt_seconds || 0)
            if (mapped) {
              return mapped
            }

            break
          }

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
            // Use the last chunk with empty choices array (has same data as choices[0].usage)
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
          {
            const mapped = mapOpenAIUsage(
              parsed.response?.usage || parsed.usage,
              current?.prompt_seconds ?? 0
            )
            if (mapped) {
              return mapped
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

export { calculateCost }
