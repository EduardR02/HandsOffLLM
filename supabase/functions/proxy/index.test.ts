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
  const replicateEndpoint = 'https://api.replicate.com/v1/predictions'

  assertEquals(shouldLogReplicateUsage(replicateEndpoint, 'POST'), true)
  assertEquals(shouldLogReplicateUsage(replicateEndpoint, 'post'), true)
  assertEquals(shouldLogReplicateUsage(replicateEndpoint), true)
  assertEquals(shouldLogReplicateUsage(replicateEndpoint, 'GET'), false)
  assertEquals(shouldLogReplicateUsage('https://api.openai.com/v1/predictions', 'POST'), false)
})

Deno.test('calculateCost resolves updated model aliases', () => {
  const gpt52MiniCost = calculateCost('openai', 'gpt-5-2-mini-latest', {
    ...EMPTY_USAGE,
    input_tokens: 1_000_000,
  })
  const codexMiniCost = calculateCost('openai', 'codex-mini-5-3-alpha', {
    ...EMPTY_USAGE,
    input_tokens: 1_000_000,
  })
  const sonnetCost = calculateCost('anthropic', 'claude-sonnet-4-6-2026-02-01', {
    ...EMPTY_USAGE,
    output_tokens: 1_000_000,
  })
  const geminiCost = calculateCost('gemini', 'gemini-3-flash-preview-001', {
    ...EMPTY_USAGE,
    cached_input_tokens: 1_000_000,
  })
  const moonshotCost = calculateCost('moonshot', 'kimi-k2-5', {
    ...EMPTY_USAGE,
    input_tokens: 1_000_000,
  })

  assertAlmostEquals(gpt52MiniCost, 0.5, 1e-9)
  assertAlmostEquals(codexMiniCost, 1.5, 1e-9)
  assertAlmostEquals(sonnetCost, 15, 1e-9)
  assertAlmostEquals(geminiCost, 0.03, 1e-9)
  assertAlmostEquals(moonshotCost, 0.6, 1e-9)
})

Deno.test('calculateCost supports fallback pricing key for mistral models', () => {
  const mistralFallbackCost = calculateCost(
    'mistral',
    'voxtral-custom-build',
    {
      ...EMPTY_USAGE,
      output_tokens: 1_000_000,
      prompt_seconds: 60,
    },
    { fallbackModelKey: 'voxtral-mini' }
  )

  assertAlmostEquals(mistralFallbackCost, 0.042, 1e-9)
})

Deno.test('containsUsageSignal gates expensive usage parsing', () => {
  assertEquals(containsUsageSignal('data: {"type":"response.delta"}'), false)
  assertEquals(containsUsageSignal('data: {"usage":{"prompt_tokens":1}}'), true)
  assertEquals(containsUsageSignal('data: {"usageMetadata":{"promptTokenCount":1}}'), true)
})

Deno.test('extractUsageFromChunk handles OpenAI response.incomplete events', () => {
  const chunk = `data: ${JSON.stringify({
    type: 'response.incomplete',
    response: {
      usage: {
        cached_input_tokens: 12,
        input_tokens: 100,
        output_tokens: 80,
        output_tokens_details: { reasoning_tokens: 30 },
      },
    },
  })}\n\n`

  const usage = extractUsageFromChunk(chunk, 'openai', null)
  assertEquals(usage, {
    cached_input_tokens: 12,
    input_tokens: 100,
    reasoning_output_tokens: 30,
    output_tokens: 80,
    cost_usd: 0,
    prompt_seconds: 0,
  })
})

Deno.test('extractUsageFromChunk handles OpenAI usage-only chunks', () => {
  const chunk = `data: ${JSON.stringify({
    usage: {
      prompt_tokens: 50,
      completion_tokens: 60,
      prompt_tokens_details: { cached_tokens: 8 },
      completion_tokens_details: { reasoning_tokens: 10 },
    },
  })}\n\n`

  const usage = extractUsageFromChunk(chunk, 'openai', null)
  assertEquals(usage, {
    cached_input_tokens: 8,
    input_tokens: 50,
    reasoning_output_tokens: 10,
    output_tokens: 60,
    cost_usd: 0,
    prompt_seconds: 0,
  })
})
