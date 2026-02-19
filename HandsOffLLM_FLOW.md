# HandsOffLLM – Required Flow

Use this as the spec for the voice loop. Any divergence is a bug.

## Conversation State
- App enters **listening** immediately after onboarding.
- Tap while listening → go **idle** (`teardown()` stops engine and clears queues). Tap while idle → call `startListening(useCooldown: false)` to re-arm the loop.
- Cancel during processing or speaking must invoke `cancelProcessingAndSpeaking()`. That emits `startListening(useCooldown: hadSpoken)` where `hadSpoken` is `true` only if audio was actually playing.
- After TTS completes, automatically return to listening with a short cooldown guard against echo-triggered VAD (`ttsPlaybackCompleteSubject` → `startListening(useCooldown: true)`).

## State Management
- `ChatViewModel` is the single source of truth for UI state. It derives `ViewModelState` from the published flags on `AudioService`/`ChatService` plus `lastError`.
- There is no event-driven coordinator; every consumer reads the same `state` and `lastError` bindings.
- Errors set `lastError` and therefore `ViewModelState.error`; clearing the error (by cancel or successful transition) returns the state to the derived value.
- Cooldown is applied inside `AudioService.startListening(useCooldown:)`; `processAudioBuffer` drops samples until the guard expires so VAD cannot trigger on residual playback. Only paths that had spoken audio pass `true`.

## Audio Capture & VAD
- Audio session: `.playAndRecord` with `.voiceChat` preferred, fallback `.default`; request 16 kHz mono; enable Bluetooth & AirPlay.
- Engine tap must produce 16 kHz mono buffers; only convert when hardware differs.
- While listening, append samples immediately; if a cooldown is active, drop input and do not accumulate.
- `speechStart` marks the first valid sample index; `speechEnd` triggers transcription.
- Timeout rule: if no `speechStart` within 60 s of entering listening, return to idle. Once speech has started, never time out.

## Transcription
- Trim captured samples using `speechStartIndex` → `speechEndIndex`.
- Encode trimmed audio to 16 kHz mono 16-bit WAV and upload via multipart to Mistral (`voxtral-mini-latest`).
- Ignore empty trims and remain in listening.

## LLM Interaction
- Every transcription becomes a `ChatMessage(role: "user")`, stored in `currentConversation` and persisted.
- Requests use sanitized conversation history (user + assistant roles only).
- Streamed chunks go through `llmChunkSubject`; when the stream finishes, flip the placeholder to `assistant`.
- `llmErrorSubject` is reserved for non-cancellation failures. `ChatViewModel` reacts by recording `lastError`, cancelling the pipeline, and restarting listening with the appropriate cooldown.
- Cancellation of in-flight LLM/TTS fetches must not surface as user-facing errors; they simply unwind back to the listening state.

## TTS Playback
- `processTTSChunk` accumulates text; `findNextTTSChunk` must honor:
  - Minimum chunk length scaled by playback rate.
  - Sentence/phrase boundaries when possible.
  - Max chunk length from settings.
- Fetch audio from OpenAI TTS with configured voice, format, and instruction. Queue chunks in order. Start fetching audio as soon as the first chunk is available to minimize latency.
- Persist each chunk via `HistoryService.saveAudioData`.
- When playback finishes and the queue is empty, emit `ttsPlaybackCompleteSubject` and resume listening with cooldown. Cancelling playback reuses the same path (hadSpoken → true).

## Persistence & Settings
- `SettingsService` controls model selection, reasoning flags, prompts, temperatures, VAD silence threshold, playback speed.
- `HistoryService` stores conversations (JSON) plus audio chunks under `Documents/Audio/<conversationID>/`.
- Audio retention:
  - `audioRetentionDays == 0` → keep everything.
  - Otherwise run daily cleanup removing conversation audio directories older than the retention window.
  - Provide a destructive manual purge option in Settings.

Keep this checklist in sync with the actual pipeline. Update it whenever the intended flow changes.***
