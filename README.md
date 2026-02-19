# HandsOffLLM

A hands-free voice interface for frontier LLMs on iOS. Talk to Claude, GPT, Gemini, Grok, or Kimi — while driving, cooking, walking, whatever.

<!-- screenshots go here -->

## Why this exists

Every major AI provider now has a "voice mode." They all share the same problem: the model behind the voice is dumbed down. ChatGPT voice mode doesn't run the frontier model — it runs something faster and dumber because they're optimizing for low latency. Same story everywhere else.

I wanted the opposite trade-off: **give me the smartest model available, and I'll wait for the answer.** A few seconds of silence is fine when you're getting an actually good response. Thinking/reasoning modes work too — the app just waits.

The other thing: I needed this hands-free. Not "tap a button and hold it" hands-free, actually hands-free. Voice Activity Detection handles when you start and stop talking. You don't touch the screen.

And honestly, talking is faster than typing. Especially for the kinds of things voice is good for — brainstorming, thinking through problems, learning, casual conversation. The voice-only constraint gives it a "just talk" quality that text chat doesn't have.

## What makes this different

- **Frontier models, not dumbed down ones.** You're talking to the actual model — Claude Opus/Sonnet, GPT-5.2, Gemini 3 Pro, whatever you pick. Quality over speed.
- **TTS speed control.** This is the single most important feature for me. I can't use anything below 2x speed. For obvious reasons, providers are disincentivized from offering fast playback in their own apps. Here, the slider goes up to 4x.
- **Hands-free with VAD.** Voice Activity Detection means you just talk. No buttons to hold, no tap-to-record. It detects when you start and stop speaking.
- **Voice interrupt.** If the model is still processing (hasn't started speaking yet), you can just start talking again and it'll cancel and listen to you instead.
- **Not vendor locked.** Switch between providers with a tap. Better model comes out? Use it immediately. Currently supports OpenAI, Anthropic, Google, xAI, and Moonshot.
- **Conversation history.** Synced and persistent, not ephemeral like most voice modes.
- **Preset modes.** Quick-select different conversation styles — brainstorming, learning, casual chat, games, and some less serious ones.

## How to use

Everything flows through the circle.

The circle is your only interaction. Tap it to interrupt or toggle listening. When you're in listening mode, just talk — VAD detects when you stop, transcribes your speech, sends it to the LLM, and speaks the response back. Then it listens again. That's the loop.

The speed slider below the circle controls TTS playback speed. This is adjustable while the model is speaking.

Swipe left (or tap the menu icon) to access settings, history, provider switching, and audio output selection.

## Setup

This is a personal project that I build onto my phone with Xcode. No App Store distribution yet.

To run it yourself:

1. Clone the repo
2. Open `HandsOffLLM.xcodeproj` in Xcode
3. Add your own API keys in Settings for the providers you want to use
4. Build and run (works on device and simulator)

### Supabase backend

By default, all API calls route through a Supabase Edge Function proxy. This keeps API keys server-side and handles auth and usage tracking. The proxy lives in `supabase/functions/`.

You can also bring your own API keys — toggle this per provider in Settings and requests go direct, bypassing the proxy entirely.

> **Note:** There's no payment system yet, so the hosted proxy isn't open for public use. If you want to run this, you'll need to either supply your own API keys or deploy your own Supabase instance.

## Tech

- Swift / SwiftUI
- AVAudioEngine for audio capture and playback
- Silero VAD for voice activity detection
- Mistral (Voxtral) for speech-to-text
- OpenAI TTS or Kokoro (via Replicate) for text-to-speech
- Supabase for auth, usage tracking, and API proxying
- Supports: OpenAI, Anthropic, Google Gemini, xAI, Moonshot

## License

MIT
