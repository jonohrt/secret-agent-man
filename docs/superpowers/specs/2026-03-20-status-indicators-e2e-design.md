# Status Indicators End-to-End

**Epic**: `secret-agent-man-k1m`
**Date**: 2026-03-20
**Branch**: `feature/blue-steel-ui`

## Problem

Status indicator dots in the SAM dashboard don't work end-to-end. TranscriptWatcher can parse JSONL transcripts correctly (unit tests pass), but it never finds the right JSONL file at runtime. The plumbing from GroupSupervisor → TranscriptWatcher already passes `workdir`, and the path encoding (`String.replace("/", "-")`) matches Claude Code's actual directory naming (verified: `~/.claude/projects/-Users-johrt-Code-secret-agent-man/` exists). So the wiring looks correct — but we've never verified it works in a live session.

**Suspected failure modes** (to be investigated in Phase 1):
1. **Workdir is nil at runtime** — user leaves the "DEPLOYMENT_VECTOR" field blank in the create dialog. Falls back to `File.cwd!()` which is SAM's cwd. This is correct only if SAM launched from the same dir Claude Code targets.
2. **Race condition** — TranscriptWatcher starts before PTY (rest_for_one ordering). It may pick up an older JSONL file from a previous session before the new one is created. The "most recently modified" heuristic handles this in steady state but fails during the startup window.
3. **Path encoding mismatch** — `String.replace(workdir, "/", "-")` needs verification against Claude Code's actual encoding for edge cases (trailing slashes, symlinks, `~` expansion).

## Success Criteria

Dashboard with 2-3 sessions where each status dot correctly reflects its session's actual state (up to ~1s latency from poll interval):
- **Starting** (pulsing blue) — session just spawned
- **Working** (green glow) — Claude executing tools
- **Idle** (gray) — no activity for 5 seconds after last tool_result
- **Done** (blue) / **Error** (red) — session exited

Note: **Needs input** is not achievable with the current JSONL-based approach — TranscriptWatcher only emits `:tool_call`, `:tool_result`, and `:turn_end`. The `:input_needed` event comes from Parser (PTY regex), which is unreliable. Deferred to a future iteration.

Verified with screenshots at each state transition, from a fresh server restart.

## Current Architecture

```
GroupSupervisor (rest_for_one)
  → Server             subscribes "session:#{id}", manages status state machine
  → Summarizer         subscribes "session:#{id}", debounced LLM summaries
  → Parser             subscribes "session:#{id}", PTY output → events
  → TranscriptWatcher  polls JSONL file every 1s, broadcasts to "session:#{id}"
  → PTY                subscribes "session_input:#{id}", Zig port
```

**Status flow (when working)**:
1. Claude Code writes tool_use to JSONL
2. TranscriptWatcher reads JSONL line, broadcasts `{:parser_event, id, %{type: :tool_call}}` to `"session:#{id}"`
3. Server receives event, transitions to `:working`, starts 5s idle timer
4. Server broadcasts `{:session_update, id, state}` to `"sessions:ui"`
5. DashboardLive updates assigns, LiveView re-renders status dot
6. CSS applies `.status-dot.working` styles

**Where it breaks**: Step 2 — TranscriptWatcher never finds the JSONL file at runtime (untested in live context).

## Design

### Phase 1: Debug and Fix JSONL File Discovery (`k1m.1`)

The workdir plumbing from GroupSupervisor → TranscriptWatcher already exists (`group_supervisor.ex:34`, `transcript_watcher.ex:19`). The path encoding appears correct. Phase 1 is a diagnostic-first task, not a blind code change.

**Step 1: Investigate with Tidewave**
- Start a session with an explicit workdir via the UI
- Use `mcp__tidewave__project_eval` to inspect TranscriptWatcher state: `workdir`, `path`, `offset`
- Verify `project_dir(workdir)` output matches actual `~/.claude/projects/` directory listing
- Check if JSONL file exists in that directory after Claude Code starts

**Step 2: Fix what's actually broken**
Based on investigation, likely fixes:
- If workdir is nil: ensure the form always sends a workdir (default to SAM's cwd in the form, not in TranscriptWatcher)
- If path encoding is wrong: fix `project_dir/1` to match Claude Code's actual encoding
- If race condition: add `session_start_time` to state, filter JSONL files by mtime > start time
- If JSONL file never appears: verify Claude Code actually writes to the expected location for the given workdir

**Step 3: TDD for the fix**
- Refactor existing TranscriptWatcher tests to remove `Process.sleep/1` (use `:sys.get_state/1` or `assert_receive`)
- Add test for the specific failure mode discovered in Step 1
- `mix precommit`

### Phase 2: E2E Manual Verification (`k1m.2`)

After Phase 1 fix is in:
1. `mix phx.server` (fresh restart)
2. Create a session with a known workdir
3. Give Claude a task that involves tool calls (e.g., "read the README")
4. Verify with Tidewave that TranscriptWatcher has correct non-nil `path`
5. Screenshot each status transition: starting → working → idle → done

### Phase 3: Wallaby E2E Tests (`k1m.3`)

Set up Wallaby for automated browser tests:
1. Add `wallaby` to `mix.exs` deps
2. Configure test endpoint for Wallaby (sandbox mode)
3. Write test: create session via UI → write mock JSONL lines to simulate Claude Code → assert status dot CSS class transitions (working → idle/done)
4. No real Claude Code needed — mock the JSONL file writes

### Phase 4: Env Var Correlation (`k1m.4` — deferred 2 weeks)

For multi-session robustness when two sessions share the same workdir:
1. Extend Zig port spawn JSON with `env` dict
2. Parse in Zig, call `setenv()` before `execvp()`
3. Pass `SAM_SESSION_ID` env var
4. TranscriptWatcher uses creation-time filtering as tiebreaker

## Dependency Chain

```
k1m.1: Debug + fix JSONL file discovery  [READY — no blockers]
  ↓ blocks
k1m.2: E2E manual verification           [blocked by k1m.1]
  ↓ blocks
k1m.3: Wallaby E2E tests                 [blocked by k1m.2]

k1m.4: Env var correlation                [deferred +2w]
```

## Out of Scope

- PTY-based status detection (disabled, staying disabled — too noisy)
- Hook-based event ingestion (separate branch `feature/hook-events-activity-feed`)
- `needs_input` state via JSONL (no JSONL record type for this; deferred)
- Status persistence across server restarts
- Multi-workdir session management UI
