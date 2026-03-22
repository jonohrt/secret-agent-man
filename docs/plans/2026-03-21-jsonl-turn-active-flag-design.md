# Fix: JSONL Turn Active Flag — PTY Prompt Race Condition

**Date:** 2026-03-21
**Branch:** feature/blue-steel-ui

## Problem

Two interacting bugs cause status to flicker to `:idle` during active tool use:

1. **PTY prompt detection fires mid-turn.** Between tool calls, Claude Code's TUI re-renders the `❯` prompt. The PTY handler sees this and immediately sets `status = :idle`, even though the JSONL transcript hasn't seen `turn_duration` yet.

2. **Prompt suppression blocks legitimate tool_calls.** After the false idle transition, the 3-second `prompt_suppression_ms` window suppresses the next `:tool_call` JSONL event. The session stays stuck at `:idle` while Claude is actively working.

## Root Cause (confirmed with test + diagnostic logging)

```
JSONL: tool_call (Read)    → status = :working
JSONL: tool_result (Read)  → starts idle timer
PTY:   ❯ prompt rendered   → BUG: status = :idle, sets prompt_detected_at
JSONL: tool_call (Grep)    → SUPPRESSED by prompt_suppression_ms → stays :idle
```

## Solution: `jsonl_turn_active` Flag

Add a boolean flag to Server state that tracks whether we're inside an active JSONL turn. When true, PTY prompt detection is skipped.

### State changes
- Add `jsonl_turn_active: false` to struct
- Remove `prompt_detected_at` field
- Remove `@prompt_suppression_ms` constant
- Remove `prompt_suppressed?/1` helper

### Flag lifecycle
- Set `true` on: `:tool_call`, `:assistant_response`, `:user_prompt`
- Set `false` on: `:turn_end`, `:idle_timeout`

### PTY prompt handler
- Skip when `jsonl_turn_active == true`
- Still fires when `jsonl_turn_active == false` (fallback for non-JSONL sessions)

### Test changes
- Update race condition test: assert status stays `:working` through PTY prompt
- Remove prompt suppression tests (mechanism deleted)
- Add test: PTY prompt ignored during active JSONL turn
- Add test: PTY prompt still works when no JSONL turn active
