export interface PricingEntry {
  input?: number
  output?: number
  cached_input?: number
  per_second?: number
  reasoning_output?: number
}

export interface CostUsage {
  cached_input_tokens: number
  input_tokens: number
  reasoning_output_tokens: number
  output_tokens: number
  prompt_seconds?: number
}

export const PRICING = {
  openai: {
    'gpt-4o': { input: 2.50, output: 10.00, cached_input: 1.25 },
    'gpt-4o-mini-tts': { input: 0.6, output: 12.00 },
    'gpt-5.2': { input: 2.00, output: 8.00, cached_input: 0.50 },
    'gpt-5.2-mini': { input: 0.50, output: 2.00, cached_input: 0.05 },
    'codex-mini-5.3': { input: 1.50, output: 6.00, cached_input: 0.375 },
  },
  anthropic: {
    'claude-sonnet-4.6': { input: 3.75, output: 15.00, cached_input: 0.30 },
    'claude-opus-4.6': { input: 18.75, output: 75.00, cached_input: 1.50 },
  },
  gemini: {
    'gemini-3-flash': { input: 0.3, output: 2.50, cached_input: 0.03 },
    'gemini-3-flash-preview': { input: 0.3, output: 2.50, cached_input: 0.03 },
    'gemini-3-pro': { input: 1.25, output: 5.00, cached_input: 0.125 },
  },
  xai: {
    'grok-4-fast': { input: 0.20, output: 0.50, cached_input: 0.05 },
    'grok-4': { input: 3.00, output: 15.00, cached_input: 0.75 },
  },
  moonshot: {
    'kimi-k2.5': { input: 0.60, output: 2.50, cached_input: 0.15 },
  },
  mistral: {
    'voxtral-mini': { input: 0.002, output: 0.04 },
  },
  replicate: {
    'kokoro-82m': { per_second: 0.000225 },
  }
}

export type PricingProvider = keyof typeof PRICING

type ModelAlias = { regex: RegExp; key: string }

export const MODEL_ALIASES: Partial<Record<PricingProvider, ModelAlias[]>> = {
  openai: [
    { regex: /^gpt-4o-mini-tts(?:$|[-_])/, key: 'gpt-4o-mini-tts' },
    { regex: /^gpt-4o(?:$|[-_])/, key: 'gpt-4o' },
    { regex: /^chatgpt-4o(?:$|[-_])/, key: 'gpt-4o' },
    { regex: /^o4-mini(?:$|[-_])/, key: 'gpt-4o' },
    { regex: /^gpt-5(?:[._-]?2)-mini(?:$|[-_])/, key: 'gpt-5.2-mini' },
    { regex: /^gpt-5(?:[._-]?2)(?:$|[-_])/, key: 'gpt-5.2' },
    { regex: /^codex-mini-5(?:[._-]?3)(?:$|[-_])/, key: 'codex-mini-5.3' },
  ],
  anthropic: [
    { regex: /^claude-sonnet-4(?:[._-]?6)(?:$|[-_])/, key: 'claude-sonnet-4.6' },
    { regex: /^claude-opus-4(?:[._-]?6)(?:$|[-_])/, key: 'claude-opus-4.6' },
  ],
  gemini: [
    { regex: /^gemini-3-flash-preview(?:$|[-_])/, key: 'gemini-3-flash-preview' },
    { regex: /^gemini-3-flash(?:$|[-_])/, key: 'gemini-3-flash' },
    { regex: /^gemini-3-pro(?:$|[-_])/, key: 'gemini-3-pro' },
  ],
  xai: [
    { regex: /^grok-4-fast(?:$|[-_])/, key: 'grok-4-fast' },
    { regex: /^grok-4(?:$|[-_])/, key: 'grok-4' },
  ],
  moonshot: [
    { regex: /^kimi-k2(?:[._-]?5)(?:$|[-_])/, key: 'kimi-k2.5' },
  ],
  mistral: [
    { regex: /^voxtral-mini(?:$|[-_])/, key: 'voxtral-mini' },
    { regex: /^voxtral(?:$|[-_])/, key: 'voxtral-mini' },
  ],
}

export function resolveModelPricing(
  provider: PricingProvider,
  model: string,
  options?: { fallbackModelKey?: string }
): PricingEntry | null {
  const providerPricing = PRICING[provider] as Record<string, PricingEntry> | undefined
  if (!providerPricing) {
    return null
  }

  const normalizedModel = model.toLowerCase()

  for (const [modelKey, pricing] of Object.entries(providerPricing)) {
    if (normalizedModel === modelKey.toLowerCase()) {
      return pricing
    }
  }

  const aliases = MODEL_ALIASES[provider] || []
  for (const { regex, key } of aliases) {
    if (regex.test(normalizedModel) && providerPricing[key]) {
      return providerPricing[key]
    }
  }

  const sortedKeys = Object.keys(providerPricing).sort((a, b) => b.length - a.length)
  for (const key of sortedKeys) {
    if (normalizedModel.includes(key.toLowerCase())) {
      return providerPricing[key]
    }
  }

  if (options?.fallbackModelKey && providerPricing[options.fallbackModelKey]) {
    return providerPricing[options.fallbackModelKey]
  }

  return null
}

export function calculateCost(
  provider: PricingProvider,
  model: string,
  usage: CostUsage,
  options?: { fallbackModelKey?: string }
): number {
  const modelPricing = resolveModelPricing(provider, model, options)
  if (!modelPricing) {
    return 0
  }

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

  const cachedInputCost = (usage.cached_input_tokens / 1_000_000) * (modelPricing.cached_input || modelPricing.input || 0)
  const inputCost = (usage.input_tokens / 1_000_000) * (modelPricing.input || 0)
  const reasoningOutputCost = (usage.reasoning_output_tokens / 1_000_000) * (modelPricing.reasoning_output || modelPricing.output || 0)
  const outputCost = (usage.output_tokens / 1_000_000) * (modelPricing.output || 0)

  return cachedInputCost + inputCost + reasoningOutputCost + outputCost
}
