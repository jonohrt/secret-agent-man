# Design: Ollama/Gemma Activity Feed Summarizer

**Date:** 2026-03-21
**Branch:** feature/blue-steel-ui
**Status:** Approved
**Bead:** secret-agent-man-f89

---

## Purpose

The activity feed currently shows raw tool names ("Read", "Bash", "Glob") — useless at a glance. Replace the Anthropic API-based summarizer with a local Ollama + Gemma 4B summarizer that answers one question: **"Do I need to read this conversation, or can I just act?"**

The activity feed is a live summary of the current conversation. Not history, not analytics. It tells the user what just happened and whether they need to take action.

## Architecture

```
JSONL transcript (last ~10 turns)
  → Summarizer extracts assistant messages + tool names
  → OllamaClient sends to Gemma 4B with actionability-focused prompt
  → 1-2 line summary → PubSub → Activity Feed

Fallback (no Ollama):
  → Last assistant text message from JSONL (Claude's own words)
  → Activity feed shows "Enhanced summaries available" nudge
```

## Components

### Sam.LLM.OllamaClient (new, replaces Sam.LLM.Client)

**File:** `lib/sam/llm/ollama_client.ex`

Talks to Ollama's REST API at `http://localhost:11434`.

**API:**
- `summarize(turns, opts \\ [])` — sends conversation turns to Gemma, returns `{:ok, summary}` or `{:error, reason}`
- `available?()` — health check, returns boolean
- `ensure_model(model)` — pulls model if not present, returns `:ok` or `{:error, reason}`

**Ollama endpoints used:**
- `GET /api/tags` — list models (check if gemma3:4b exists)
- `POST /api/generate` — generate summary (non-streaming, `stream: false`)
- `POST /api/pull` — pull model if missing

**Model:** `gemma3:4b` (default, configurable)

**Prompt:**
```
You are summarizing an AI coding agent's activity for a dashboard.
In 1-2 lines, tell the user what just happened and whether they need to take action.
Don't describe tools or process — describe outcomes and decisions.

Conversation:
<turns inserted here>
```

**Behavior:**
- On first call, check if model is available. If not, auto-pull it (one-time, may take a minute).
- If Ollama is not running, return `{:error, :ollama_unavailable}` immediately (no retry/crash).
- Timeout: 10s for generate, 300s for model pull.
- No GenServer — stateless module with `Req` HTTP calls. Ollama manages its own state.

### Sam.Session.Summarizer (modified)

**File:** `lib/sam/session/summarizer.ex`

**Changes:**
- Replace input construction: instead of building `"Used Read on file.ex"` strings from parser events, extract the last ~10 conversation turns from the JSONL transcript.
- The Summarizer needs access to the JSONL file path. It already subscribes to `"session:#{id}"` PubSub — it will receive `{:journal_found, path}` forwarded by TranscriptWatcher (or listen for `{:summary_context, path}` from Server).
- On summarize trigger: read last ~10 turns from JSONL, extract assistant message text and tool names (not full tool input/output), pass to `OllamaClient.summarize/2`.
- On Ollama failure: fall back to extracting the last assistant text message from the JSONL (Claude's own description of what it's doing).
- Same debounce (5s after decision point event, matching existing `@default_debounce_ms`), same PubSub broadcast pattern.
- JSONL path: Summarizer receives `{:journal_found, path}` via PubSub (already subscribed to `"session:#{id}"`). Stores path in struct for reading turns on demand.
- Model pull: if `ensure_model` triggers a pull, run it via `Task.start` (fire-and-forget) and use JSONL fallback for that summary. Don't block the GenServer.

**Turn extraction from JSONL:**
- Read the JSONL file, take the last ~10 records that have `message.role` of `"assistant"` or `"user"`
- For assistant messages: extract text content blocks (skip base64/image content)
- For tool_use in assistant messages: include just the tool name
- For user messages with tool_result: skip the full output, just note "tool completed"
- Cap total input to ~2000 chars to keep Gemma fast

### Sam.LLM.Client (deleted)

Remove `lib/sam/llm/client.ex` entirely. No Anthropic API dependency.

### Activity Feed UI (modified)

**File:** `lib/sam_web/live/dashboard_live.ex`

When Ollama is unavailable and fallback is in use, show a subtle nudge at the top of the activity feed:

```
⚡ Install Ollama for AI-powered summaries → ollama.com
```

This is a single line, muted styling, dismissible. Only shown when `OllamaClient.available?()` returns false (checked once on mount, cached in assigns).

### Ollama Auto-Pull Behavior

On first summarize call:
1. Check `GET /api/tags` for `gemma3:4b`
2. If missing: `POST /api/pull {"name": "gemma3:4b"}`
3. Pull happens once, blocks that first summary (fallback used meanwhile)
4. Subsequent calls use the now-available model

This means: if a user installs Ollama and starts SAM, the first summary may take a minute (model download), but after that it's instant. No manual `ollama pull` step needed.

## Fallback Strategy

Three tiers:
1. **Ollama + Gemma available** → rich 1-2 line summary from Gemma
2. **Ollama running, Gemma pulling** → fallback to last assistant text from JSONL while model downloads
3. **No Ollama** → fallback to last assistant text from JSONL + nudge in UI

The JSONL fallback extracts the last assistant message's text content. Since Claude Code describes what it's doing in natural language, this is already a reasonable (if verbose) summary. Not as concise as Gemma, but answers "what's happening" better than raw tool names.

## Testing Strategy

### OllamaClient Tests
- **Unit:** `summarize/2` returns `{:ok, summary}` when Ollama responds correctly (mock HTTP)
- **Unit:** `summarize/2` returns `{:error, :ollama_unavailable}` when connection refused
- **Unit:** `available?/0` returns true/false based on health check response
- **Unit:** `ensure_model/1` calls pull API when model not in tags list

### Summarizer Tests
- **Unit:** Extracts last ~10 turns from JSONL file correctly
- **Unit:** Caps input at ~2000 chars
- **Unit:** Falls back to last assistant text when OllamaClient returns error
- **Unit:** Broadcasts summary via PubSub on successful summarization

### Integration
- **Integration:** Full flow: JSONL with conversation → Summarizer → OllamaClient → summary broadcast (requires Ollama running, tagged as optional/integration test)

## No New Dependencies

Ollama HTTP API called via `Req` (already in deps). No new hex packages needed.
