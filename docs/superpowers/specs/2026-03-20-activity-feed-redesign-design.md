# Activity Feed Redesign — Intent Summaries via Local LLM

**Date:** 2026-03-20
**Status:** Draft

## Problem

The activity feed currently shows raw tool names and truncated commands (e.g., "Read: /assets/js/terminal.js", "Bash: git log --oneline main.."). This is noise — it tells you *how* the agent works, not *what* it's doing. The feed should provide at-a-glance intent summaries like "Investigating xterm.js drag-and-drop support" so the user can decide whether to look at the full transcript.

## Solution

Rewrite the existing Summarizer GenServer to use a local Ollama instance running Gemma 3 4B for summarization, with a heuristic fallback when Ollama is unavailable. No API keys required for the default path.

## Architecture

### Summarizer Rewrite

The existing `Sam.Session.Summarizer` GenServer keeps its current buffering and debounce logic. The backend changes:

- **Old:** Calls `Sam.LLM.Client.summarize/1` (requires Anthropic API key)
- **New:** Calls `Sam.LLM.Ollama.summarize/2` (local, free) with heuristic fallback

Batching window: ~5 seconds. Collect tool_use events, then summarize the batch as one feed entry.

### Data Flow

1. TranscriptWatcher tails JSONL → emits `{:parser_event, session_id, %{type: :tool_call, ...}}`
2. Hook events arrive via HookController → same PubSub path
3. Summarizer subscribes, buffers events for ~5s, then:
   - Ollama available → sends batch to Gemma → gets one-liner summary
   - No Ollama → heuristic label from tool descriptions/inputs
4. Summarizer broadcasts `{:summary, session_id, %{text: "...", tool_count: 3, timestamp: ...}}`
5. Server receives summary → adds to `state.activity` list
6. Server broadcasts `{:session_update, ...}` → LiveView renders feed

**Key change:** Activity entries come from Summarizer output only, not raw tool events. The `:tool_call`/`:pre_tool_call` handlers in Server **keep their status-transition logic** (idle → working → background) but **drop the `add_activity` call**. One source of truth for the feed.

**Server wiring:** The existing `handle_info({:summary, ...})` in Server is currently a no-op discard clause (line ~219). This must be replaced with logic that creates an activity entry from the summary payload and appends it to `state.activity`.

### Ollama Client (`Sam.LLM.Ollama`)

Thin HTTP client for local Ollama:

- **Health check on startup:** `GET http://localhost:11434/api/tags` → parse available models
- **Model preference chain:** `gemma3:4b` → `gemma3:1b` → any gemma model → `:heuristic`
- **Chat endpoint:** `POST http://localhost:11434/api/chat` with tool call batch
- **Timeout:** 5 second hard cap — slow/hung Ollama falls back to heuristic for that batch
- **Error handling:** Any non-success HTTP response, malformed JSON, empty/garbage model output, or model-not-loaded error falls back to heuristic for that batch and logs the error. No crash, no retry.
- **Reconnect:** Periodic health check every 60s so Ollama started mid-session is detected. Additionally, trigger an immediate recheck on the next batch after a heuristic fallback, so recovery is faster than 60s.

**Summarization prompt:**
> You are summarizing a coding agent's actions for a dashboard activity feed. Given these tool calls, write one short sentence describing what the agent is doing. Be concise — 10 words or fewer preferred.

### Heuristic Fallback

When Ollama is unavailable, generate labels from tool call event fields by priority:

1. Event has `:description` field (present on hook events for Bash, Agent) → use directly ("Check beads for open issues")
2. Event has `:file` or `:pattern` field (Read/Glob/Grep) → generate from path ("Reading terminal.js", "Searching for screenshots")
3. Event has `:prompt` field (Agent) → use the `description` from input ("Exploring activity feed implementation")
4. Multiple same-tool calls in batch → group ("Reading 3 files in lib/sam/session/")
5. None of the above → fall back to tool name ("Bash", "Read")

Note: hook events (from HookController) carry `description` reliably. TranscriptWatcher-parsed JSONL events may only have `tool` and `file`. The fallback chain handles both sources.

### Settings Integration

The existing `Sam.Settings` GenServer stores:

- Detected summarization mode: `:ollama_4b`, `:ollama_1b`, `:heuristic`
- Small status indicator in UI shows active backend

**Out of scope (future work):** OpenRouter API key as cloud override. This would allow users to use a cloud model instead of local Ollama. Deferred until there's demand — local Ollama covers the zero-config goal.

### Activity Entry Format

```elixir
%{
  type: :summary,           # New type replacing :tool
  text: "Analyzing JSONL transcript structure",
  timestamp: ~U[2026-03-20 14:36:00Z],
  tool_count: 3             # Number of tool calls in this batch
}
```

Activity list cap remains at 50 entries. Since summary entries are coarser-grained (one per ~5s batch vs one per tool call), 50 entries covers significantly more session history.

**LiveView update:** The dashboard template and `activity_msg_class/1` helper must be updated to handle `type: :summary` entries. The old `type: :tool` entries will no longer be produced.

## Model Requirements

| Model | Download | RAM | Audience |
|-------|----------|-----|----------|
| Gemma 3 4B (preferred) | 3.3GB | ~4GB | Any modern dev machine |
| Gemma 3 1B (fallback) | 800MB | ~2GB | Low-spec machines |

Target users run AI coding agents — they have capable hardware. 4B is the default recommendation.

## Testing

- **Ollama client:** Mock HTTP responses, test model detection chain, test timeout/fallback, test error handling (500, malformed JSON, empty response)
- **Summarizer:** Test batching/debounce with mock Ollama, test heuristic fallback on `:unavailable`
- **Heuristic labels:** Pure function tests — tool call inputs → correct labels (`async: true`). Cover events with `:description`, events with only `:file`, events with neither.
- **Integration:** Summarizer → Server pipeline — send tool events, assert activity feed gets summary text (not raw tool names)
- **E2E:** Manual verification with Ollama running — spawn session, observe feed shows summaries

## Files Modified

- `lib/sam/session/summarizer.ex` — Rewrite backend to use Ollama client
- `lib/sam/session/server.ex` — Replace summary discard handler with activity-feed wiring, remove `add_activity` from tool_call handlers (keep status transitions)
- `lib/sam/settings.ex` — Store summarization mode
- `lib/sam_web/live/dashboard_live.ex` — Handle `:summary` type entries, show backend status indicator

## Files Added

- `lib/sam/llm/ollama.ex` — Ollama HTTP client with health check, model detection, summarization
- `test/sam/llm/ollama_test.exs` — Ollama client tests
- Updated tests for summarizer, server, and heuristic label generation
