# Fix Ghost Terminals, Status Indicator, and Sessions Panel

**Date:** 2026-03-21
**Branch:** feature/blue-steel-ui

## Problem Statement

Three bugs are stuck in a loop after 4+ attempts:

1. **Status stuck on idle** — Hooks are not installed in `~/.claude/settings.json`. `register_hooks!` exists but is never called. No hook events fire, so status never changes from `:idle`.

2. **Ghost terminals after restart** — DETS persists sessions. On restart, saved sessions with no running GenServer become "ghost" entries in the tab bar. Users must manually dismiss them.

3. **Sessions panel = Activity feed** — `session_summary_text/1` filters the `activity` list for `source: :ollama` entries, but those same entries also appear in the activity feed. Both panels show identical text.

## Design

### 1. Status Indicator — Auto-Register Hooks on Startup

**File: `lib/sam/application.ex`**
- Call `Sam.Hooks.ClaudeCodeHooks.ensure_registered!()` after the endpoint starts

**File: `lib/sam/hooks/claude_code_hooks.ex`**
- Rename `register_hooks!` → `ensure_registered!` (idempotent: check first, register only if needed)
- Use `check_and_prompt/0` internally to skip if already installed
- Create `~/.claude/hooks/` directory if it doesn't exist

**Hook script behavior (already correct):**
- Reads `SAM_SESSION_ID` from env (set by PTY when SAM spawns the session)
- Exits cleanly if `SAM_SESSION_ID` is unset (non-SAM sessions are ignored)
- Posts to `http://localhost:${SAM_PORT:-4000}/api/hooks`

**Result:** SAM-spawned sessions get working status indicators. External sessions are unaffected.

### 2. Ghost Terminals — Clean DETS on Startup

**File: `lib/sam/persistence.ex`**
- In `init/1`, after opening DETS, call `cleanup_stale(table)` which deletes all entries (at boot time, no GenServers are running yet, so all entries are stale)

**Result:** Server restart = clean slate. No ghost terminals.

### 3. Sessions Panel — Dedicated Summary Field

**File: `lib/sam/session/server.ex`**
- Add `summary: "Awaiting directives..."` to the struct
- In `handle_info({:summary, ...})`: update both `activity` list (chronological log) AND `summary` field (latest summary text)

**File: `lib/sam_web/live/dashboard_live.ex`**
- Session cards read `state.summary` directly instead of calling `session_summary_text/1`
- Remove `session_summary_text/1` and `raw_session_summary_text/1` helper functions
- Ghost sessions get `summary: "Disconnected"` default
- `load_sessions/0` and `handle_info(:session_update, ...)` include `summary` in the session map

**File: `lib/sam/persistence.ex`**
- Include `summary` in serialized data

**Result:** Session cards show latest summary. Activity feed shows full chronological log. They're independent.

## Testing

- Server test: verify summary updates both `activity` and `summary` fields
- Server test: verify hook events trigger status transitions
- Persistence test: verify stale cleanup on init
- Manual: restart server, create session through UI, observe status changes
