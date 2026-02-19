// HandsOffLLM dedicated transcription proxy
// Accepts multipart uploads from clients, injects app credentials, logs usage.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import {
  checkUserQuota,
  createSupabaseClients,
  DISABLE_USAGE_TRACKING,
  insertUsageLog,
  validateJwt,
} from "../_shared/auth.ts";
import { CORS_HEADERS, handleCorsOptions } from "../_shared/cors.ts";
import { calculateCost } from "../_shared/pricing.ts";

interface UsageData {
  prompt_audio_seconds: number;
  completion_tokens: number;
}

const handler = async (req: Request) => {
  const corsResponse = handleCorsOptions(req);
  if (corsResponse) {
    return corsResponse;
  }

  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  try {
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

    const { supabaseAuth, supabaseAdmin } = createSupabaseClients(authHeader);
    const { user, response: authResponse } = await validateJwt(supabaseAuth);
    if (authResponse || !user) {
      return authResponse ?? new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      });
    }

    const quotaResponse = await checkUserQuota(supabaseAdmin, user.id);
    if (quotaResponse) {
      return quotaResponse;
    }

    const formData = await req.formData();

    const file = formData.get("file");
    if (!(file instanceof File)) {
      return new Response(JSON.stringify({ error: "Missing audio file" }), {
        status: 400,
        headers: { "Content-Type": "application/json" },
      });
    }

    const model = (formData.get("model") as string | null) ?? "voxtral-mini-2602";

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
      const cost = calculateCost(
        "mistral",
        model,
        {
          cached_input_tokens: 0,
          input_tokens: 0,
          reasoning_output_tokens: 0,
          output_tokens: usage.completion_tokens,
          prompt_seconds: usage.prompt_audio_seconds,
        },
        { fallbackModelKey: "voxtral-mini" },
      );

      await insertUsageLog(supabaseAdmin, {
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
        "Access-Control-Allow-Origin": CORS_HEADERS["Access-Control-Allow-Origin"],
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
};

if (import.meta.main) {
  serve(handler);
}
