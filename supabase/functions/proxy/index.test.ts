import {
  assertAlmostEquals,
  assertEquals,
} from "https://deno.land/std@0.168.0/testing/asserts.ts"

import {
  calculateCost,
  containsUsageSignal,
  estimateReplicateSeconds,
  extractUsageFromChunk,
  isSSEContentType,
  shouldLogReplicateUsage,
} from "./index.ts"

const EMPTY_USAGE = {
  cached_input_tokens: 0,
  input_tokens: 0,
  reasoning_output_tokens: 0,
  output_tokens: 0,
  cost_usd: 0,
}

// Helper to wrap a JSON object as an SSE data line
function sse(obj: unknown): string {
  return `data: ${JSON.stringify(obj)}\n\n`
}

// ── Helpers ──────────────────────────────────────────────────────

Deno.test('isSSEContentType identifies SSE responses', () => {
  assertEquals(isSSEContentType('text/event-stream'), true)
  assertEquals(isSSEContentType('text/event-stream; charset=utf-8'), true)
  assertEquals(isSSEContentType('application/json'), false)
})

Deno.test('estimateReplicateSeconds enforces minimum billing duration', () => {
  assertAlmostEquals(estimateReplicateSeconds(''), 0.3, 1e-9)
  assertAlmostEquals(estimateReplicateSeconds('x'.repeat(750)), 60, 1e-9)
})

Deno.test('shouldLogReplicateUsage only logs initial replicate posts', () => {
  const ep = 'https://api.replicate.com/v1/predictions'
  assertEquals(shouldLogReplicateUsage(ep, 'POST'), true)
  assertEquals(shouldLogReplicateUsage(ep, 'post'), true)
  assertEquals(shouldLogReplicateUsage(ep), true)
  assertEquals(shouldLogReplicateUsage(ep, 'GET'), false)
  assertEquals(shouldLogReplicateUsage('https://api.openai.com/v1/predictions', 'POST'), false)
})

Deno.test('containsUsageSignal gates expensive usage parsing', () => {
  assertEquals(containsUsageSignal('data: {"type":"response.delta"}'), false)
  assertEquals(containsUsageSignal('data: {"usage":{"prompt_tokens":1}}'), true)
  assertEquals(containsUsageSignal('data: {"usageMetadata":{"promptTokenCount":1}}'), true)
})

// ── Cost calculation ─────────────────────────────────────────────

Deno.test('calculateCost resolves updated model aliases', () => {
  assertAlmostEquals(
    calculateCost('openai', 'gpt-5-2-mini-latest', { ...EMPTY_USAGE, input_tokens: 1_000_000 }),
    0.5, 1e-9
  )
  assertAlmostEquals(
    calculateCost('openai', 'codex-mini-5-3-alpha', { ...EMPTY_USAGE, input_tokens: 1_000_000 }),
    1.5, 1e-9
  )
  assertAlmostEquals(
    calculateCost('anthropic', 'claude-sonnet-4-6-2026-02-01', { ...EMPTY_USAGE, output_tokens: 1_000_000 }),
    15, 1e-9
  )
  assertAlmostEquals(
    calculateCost('gemini', 'gemini-3-flash-preview-001', { ...EMPTY_USAGE, cached_input_tokens: 1_000_000 }),
    0.03, 1e-9
  )
  assertAlmostEquals(
    calculateCost('moonshot', 'kimi-k2-5', { ...EMPTY_USAGE, input_tokens: 1_000_000 }),
    0.6, 1e-9
  )
})

Deno.test('calculateCost supports fallback pricing key for mistral', () => {
  assertAlmostEquals(
    calculateCost('mistral', 'voxtral-custom-build',
      { ...EMPTY_USAGE, output_tokens: 1_000_000, prompt_seconds: 60 },
      { fallbackModelKey: 'voxtral-mini' }
    ),
    0.042, 1e-9
  )
})

Deno.test('calculateCost returns 0 for unknown model with no fallback', () => {
  assertEquals(
    calculateCost('openai', 'totally-fake-model', { ...EMPTY_USAGE, input_tokens: 1_000_000 }),
    0
  )
})

// ── OpenAI usage extraction ──────────────────────────────────────

Deno.test('extractUsage: OpenAI response.completed', () => {
  const usage = extractUsageFromChunk(sse({
    type: 'response.completed',
    response: { usage: { input_tokens: 200, output_tokens: 150, cached_input_tokens: 50 } },
  }), 'openai', null)

  assertEquals(usage!.input_tokens, 200)
  assertEquals(usage!.output_tokens, 150)
  assertEquals(usage!.cached_input_tokens, 50)
})

Deno.test('extractUsage: OpenAI response.incomplete with reasoning', () => {
  const usage = extractUsageFromChunk(sse({
    type: 'response.incomplete',
    response: { usage: {
      cached_input_tokens: 12, input_tokens: 100, output_tokens: 80,
      output_tokens_details: { reasoning_tokens: 30 },
    }},
  }), 'openai', null)

  assertEquals(usage!.reasoning_output_tokens, 30)
  assertEquals(usage!.output_tokens, 80)
})

Deno.test('extractUsage: OpenAI usage-only chunk (chat completions format)', () => {
  const usage = extractUsageFromChunk(sse({
    usage: {
      prompt_tokens: 50, completion_tokens: 60,
      prompt_tokens_details: { cached_tokens: 8 },
      completion_tokens_details: { reasoning_tokens: 10 },
    },
  }), 'openai', null)

  assertEquals(usage!.cached_input_tokens, 8)
  assertEquals(usage!.input_tokens, 50)
  assertEquals(usage!.reasoning_output_tokens, 10)
  assertEquals(usage!.output_tokens, 60)
})

// ── Anthropic usage extraction ───────────────────────────────────

Deno.test('extractUsage: Anthropic message_start', () => {
  const usage = extractUsageFromChunk(sse({
    type: 'message_start',
    message: { usage: { input_tokens: 300, output_tokens: 0, cache_read_input_tokens: 100, cache_creation_input_tokens: 20 }},
  }), 'anthropic', null)

  assertEquals(usage!.input_tokens, 300)
  assertEquals(usage!.cached_input_tokens, 120) // 100 + 20
  assertEquals(usage!.output_tokens, 0)
})

Deno.test('extractUsage: Anthropic message_delta updates output tokens', () => {
  const initial = {
    cached_input_tokens: 50, input_tokens: 200,
    reasoning_output_tokens: 0, output_tokens: 0,
    cost_usd: 0, prompt_seconds: 0,
  }
  const usage = extractUsageFromChunk(sse({
    type: 'message_delta',
    usage: { output_tokens: 450 },
  }), 'anthropic', initial)

  assertEquals(usage!.output_tokens, 450)
  assertEquals(usage!.input_tokens, 200) // preserved from initial
})

// ── Gemini usage extraction ──────────────────────────────────────

Deno.test('extractUsage: Gemini usageMetadata', () => {
  const usage = extractUsageFromChunk(sse({
    usageMetadata: {
      promptTokenCount: 500, candidatesTokenCount: 250,
      cachedContentTokenCount: 100, thoughtsTokenCount: 75,
    },
  }), 'gemini', null)

  assertEquals(usage!.input_tokens, 500)
  assertEquals(usage!.output_tokens, 250)
  assertEquals(usage!.cached_input_tokens, 100)
  assertEquals(usage!.reasoning_output_tokens, 75)
})

Deno.test('extractUsage: Gemini usageMetadata with no thinking', () => {
  const usage = extractUsageFromChunk(sse({
    usageMetadata: { promptTokenCount: 100, candidatesTokenCount: 50 },
  }), 'gemini', null)

  assertEquals(usage!.reasoning_output_tokens, 0)
  assertEquals(usage!.cached_input_tokens, 0)
})

// ── xAI usage extraction ────────────────────────────────────────

Deno.test('extractUsage: xAI final chunk with empty choices', () => {
  const usage = extractUsageFromChunk(sse({
    choices: [],
    usage: {
      prompt_tokens: 400, completion_tokens: 300,
      prompt_tokens_details: { cached_tokens: 80 },
      completion_tokens_details: { reasoning_tokens: 100 },
    },
  }), 'xai', null)

  assertEquals(usage!.input_tokens, 400)
  assertEquals(usage!.cached_input_tokens, 80)
  assertEquals(usage!.reasoning_output_tokens, 100)
  assertEquals(usage!.output_tokens, 200) // 300 - 100
})

Deno.test('extractUsage: xAI ignores chunks with non-empty choices', () => {
  const usage = extractUsageFromChunk(sse({
    choices: [{ delta: { content: 'hello' } }],
    usage: { prompt_tokens: 10, completion_tokens: 5 },
  }), 'xai', null)

  assertEquals(usage, null)
})

// ── Moonshot usage extraction ────────────────────────────────────

Deno.test('extractUsage: Moonshot final chunk with empty choices', () => {
  const usage = extractUsageFromChunk(sse({
    choices: [],
    usage: {
      prompt_tokens: 600, completion_tokens: 500,
      prompt_tokens_details: { cached_tokens: 150 },
      completion_tokens_details: { reasoning_tokens: 200 },
    },
  }), 'moonshot', null)

  assertEquals(usage!.input_tokens, 600)
  assertEquals(usage!.cached_input_tokens, 150)
  assertEquals(usage!.reasoning_output_tokens, 200)
  assertEquals(usage!.output_tokens, 300) // 500 - 200
})

// ── Mistral usage extraction ─────────────────────────────────────

Deno.test('extractUsage: Mistral with audio seconds', () => {
  const usage = extractUsageFromChunk(sse({
    usage: { prompt_tokens: 0, completion_tokens: 42, prompt_audio_seconds: 12.5 },
  }), 'mistral', null)

  assertEquals(usage!.output_tokens, 42)
  assertEquals(usage!.prompt_seconds, 12.5)
  assertEquals(usage!.input_tokens, 0)
})

// ── Edge cases ───────────────────────────────────────────────────

Deno.test('extractUsage: returns null for data: [DONE]', () => {
  assertEquals(extractUsageFromChunk('data: [DONE]\n\n', 'openai', null), null)
})

Deno.test('extractUsage: returns null for content-only delta (no usage)', () => {
  assertEquals(extractUsageFromChunk(sse({
    choices: [{ delta: { content: 'hello world' } }],
  }), 'xai', null), null)
})

Deno.test('extractUsage: handles malformed JSON gracefully', () => {
  assertEquals(extractUsageFromChunk('data: {broken json\n\n', 'openai', null), null)
})

Deno.test('extractUsage: non-SSE JSON fallback for Anthropic', () => {
  const raw = JSON.stringify({
    usage: { input_tokens: 100, output_tokens: 200, cache_read_input_tokens: 30 },
  })
  const usage = extractUsageFromChunk(raw, 'anthropic', null)

  assertEquals(usage!.input_tokens, 100)
  assertEquals(usage!.output_tokens, 200)
  assertEquals(usage!.cached_input_tokens, 30)
})
