// HandsOffLLM dedicated transcription proxy
// Accepts multipart uploads from clients, injects app credentials, logs usage.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type PricingEntry = { input?: number; output?: number };

const PRICING: Record<string, Record<string, PricingEntry>> = {
  mistral: {
    "voxtral-mini": { input: 0.002, output: 0.04 },
    "voxtral-mini-latest": { input: 0.002, output: 0.04 },
  },
};

const MODEL_ALIASES = [
  { regex: /^voxtral-mini(?:[-_].+)?$/i, key: "voxtral-mini" },
  { regex: /^voxtral-mini-latest$/i, key: "voxtral-mini-latest" },
];

interface UsageData {
  prompt_audio_seconds: number;
  completion_tokens: number;
}

const DISABLE_USAGE_TRACKING =
  (Deno.env.get("DISABLE_USAGE_TRACKING") ?? "false").toLowerCase() === "true";

function resolvePricing(model: string): PricingEntry {
  const pricing = PRICING.mistral;
  const exact = pricing[model];
  if (exact) return exact;

  for (const alias of MODEL_ALIASES) {
    if (alias.regex.test(model)) {
      const mapped = pricing[alias.key];
      if (mapped) return mapped;
    }
  }

  const fallback = pricing["voxtral-mini"];
  return fallback ?? { input: 0, output: 0 };
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers":
          "authorization, x-client-info, apikey, content-type",
      },
    });
  }

  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const mistralApiKey = Deno.env.get("MISTRAL_API_KEY");
    const authHeader = req.headers.get("Authorization");

    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Missing Authorization" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      });
    }

    if (!mistralApiKey) {
      return new Response(
        JSON.stringify({ error: "Mistral API key not configured" }),
        {
          status: 500,
          headers: { "Content-Type": "application/json" },
        },
      );
    }

    const supabaseAuth = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const supabaseAdmin = (!DISABLE_USAGE_TRACKING && supabaseServiceKey)
      ? createClient(supabaseUrl, supabaseServiceKey)
      : null;

    const {
      data: { user },
      error: authError,
    } = await supabaseAuth.auth.getUser();

    if (authError || !user) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      });
    }

    // Check rate limit and quota using optimized functions
    if (!DISABLE_USAGE_TRACKING && supabaseAdmin) {
      // Rate limiting: 30 requests per minute per user
      const { data: rateLimitOk } = await supabaseAdmin.rpc("check_rate_limit", {
        p_user_id: user.id,
        p_max_requests: 30,
      });

      if (!rateLimitOk) {
        return new Response(
          JSON.stringify({
            error: "Rate limit exceeded",
            limit: "30 requests per minute",
          }),
          {
            status: 429,
            headers: {
              "Content-Type": "application/json",
              "Retry-After": "60",
            },
          },
        );
      }

      // Check quota using optimized combined query
      const { data: quotaData, error: quotaError } = await supabaseAdmin.rpc(
        "check_user_quota",
        { p_user_id: user.id },
      );

      if (quotaError) {
        console.error("Quota check failed:", quotaError);
        return new Response(
          JSON.stringify({ error: "Failed to check usage quota" }),
          {
            status: 500,
            headers: { "Content-Type": "application/json" },
          },
        );
      }

      const quota = quotaData?.[0];
      if (quota?.quota_exceeded) {
        return new Response(
          JSON.stringify({
            error: "Monthly usage limit exceeded",
            current_usage: quota.current_usage,
            limit: quota.monthly_limit,
          }),
          {
            status: 429,
            headers: { "Content-Type": "application/json" },
          },
        );
      }
    }

    const formData = await req.formData();

    const file = formData.get("file");
    if (!(file instanceof File)) {
      return new Response(JSON.stringify({ error: "Missing audio file" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }

    const model = (formData.get("model") as string | null) ?? "voxtral-mini-latest";

    const forwardForm = new FormData();
    forwardForm.append("file", file, file.name);
    forwardForm.append("model", model);

    const mistralResponse = await fetch(
      "https://api.mistral.ai/v1/audio/transcriptions",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${mistralApiKey}`,
        },
        body: forwardForm,
      },
    );

    const responseBuffer = await mistralResponse.arrayBuffer();
    const responseText = new TextDecoder().decode(responseBuffer);

    if (!mistralResponse.ok) {
      return new Response(responseText, {
        status: mistralResponse.status,
        headers: {
          "Content-Type":
            mistralResponse.headers.get("Content-Type") ?? "application/json",
        },
      });
    }

    let usage: UsageData | null = null;
    try {
      const parsed = JSON.parse(responseText);
      if (parsed?.usage) {
        usage = {
          prompt_audio_seconds: parsed.usage.prompt_audio_seconds ?? 0,
          completion_tokens: parsed.usage.completion_tokens ?? 0,
        };
      }
    } catch (_err) {
      usage = null;
    }

    if (usage && !DISABLE_USAGE_TRACKING && supabaseAdmin) {
      const pricing = resolvePricing(model.toLowerCase());
      const minutes = usage.prompt_audio_seconds / 60;
      const cost = minutes * (pricing.input ?? 0) +
        (usage.completion_tokens / 1_000_000) * (pricing.output ?? 0);

      await supabaseAdmin.from("usage_logs").insert({
        user_id: user.id,
        provider: "mistral",
        model,
        cached_input_tokens: 0,
        input_tokens: 0,
        reasoning_output_tokens: 0,
        output_tokens: usage.completion_tokens,
        cost_usd: cost,
      });
    }

    return new Response(responseBuffer, {
      headers: {
        "Content-Type":
          mistralResponse.headers.get("Content-Type") ?? "application/json",
        "Access-Control-Allow-Origin": "*",
      },
    });
  } catch (error) {
    console.error("Transcription proxy error:", error);
    return new Response(
      JSON.stringify({ error: "Internal server error", message: error.message }),
      {
        status: 500,
        headers: { "Content-Type": "application/json" },
      },
    );
  }
});
