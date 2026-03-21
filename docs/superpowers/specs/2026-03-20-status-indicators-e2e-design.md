# Status Indicators: E2E Tests & State Machine

**Date**: 2026-03-20
**Branch**: `feature/blue-steel-ui`

## Problem

Status indicator has been through 8+ iterations without reliable end-to-end verification. Each fix was tested via hot-reload against stale GenServer state, producing false positives. We need automated E2E tests that define "done" and can be run after a clean server restart.

## Status States

| State | Badge | Meaning |
|---|---|---|
| `:idle` | IDLE (gray) | At prompt, nothing happening |
| `:working` | WORKING (green) | Main agent actively processing |
| `:background` | BACKGROUND (blue pulse) | Main idle, subagents still running |
| `:needs_input` | NEEDS INPUT (yellow) | Permission prompt detected |
| `:done` | DONE (blue) | Session exited cleanly (exit 0) |
| `:error` | ERROR (red) | Session crashed (exit non-zero) |

**Removed states**: `:starting` and `:running` from the original CLAUDE.md state machine are removed. A session that hasn't done anything is `:idle`. The struct default and `init/1` both set `:idle`. CLAUDE.md will be updated to match.

## Transitions

```
                    ┌──────────────────────────┐
                    │                          │
  create ──► :idle ──► :working ──► :idle     │
                ▲       │    │       │         │
                │       │    │       ▼         │
                │       │    │   :background ──┘
                │       │    │       │    (last agent done)
                │       │    ▼       │
                │       │  :needs_input
                │       │    │
                │       │    │ (user responds)
                │       ▼    ▼
                │     :done / :error
                │
                └── (idle timeout + no active subagents)
```

### Trigger Details

| # | From | To | Trigger |
|---|---|---|---|
| 1 | (new) | `:idle` | Session created |
| 2 | `:idle` | `:working` | `send_input` with `\n` or `\r` |
| 3 | `:idle` | `:working` | PreToolUse hook fires |
| 4 | `:working` | `:working` | PreToolUse hook (stays working, no timer) |
| 5 | `:working` | `:idle` | PostToolUse + idle timeout (5s) + no active subagents |
| 6 | `:working` | `:background` | PostToolUse + idle timeout + subagents still `:working` |
| 7 | `:background` | `:idle` | Last subagent completes |
| 8 | `:background` | `:working` | User sends new input |
| 9 | `:idle`/`:working` | `:needs_input` | PTY output matches permission pattern |
| 10 | `:needs_input` | `:working` | User sends input (Enter key) |
| 11 | any | `:done` | PTY exit code 0 |
| 12 | any | `:error` | PTY exit code non-zero |

### Subagent Tracking

| Event | Action |
|---|---|
| PreToolUse hook with tool=Agent | Add entry to `agents` list as `:working` with description |
| PostToolUse hook with tool=Agent | Mark that agent entry as `:done` |
| Agents panel | Renders each subagent as a row with status dot + description |
| Active count | Panel header shows count of `:working` subagents |

## New Implementation Required

The following does NOT exist in the codebase yet and must be built:

1. **`:background` state** — Add to Server state machine. When idle timeout fires, check `agents` list for any `:working` entries. If yes → `:background`, if no → `:idle`.
2. **Subagent tracking** — Server must handle PreToolUse/PostToolUse events where tool=Agent. Add/update entries in the `agents` list with `%{id: unique, description: desc, status: :working/:done}`.
3. **`:needs_input` → `:working` transition** — Current code only transitions to `:working` from `:idle` on `send_input`. Must also handle `:needs_input` and `:background` states.
4. **Agents panel rendering** — Dashboard template currently hardcodes "main" + "1 ACTIVE". Must render from `state.agents` list and compute active count dynamically.
5. **Terminal state protection** — `:done` and `:error` are absorbing states. No hook events or input should change status after exit.

## E2E Test Design

### Approach: Mock Agent

Instead of spawning real Claude Code (slow, flaky, costs tokens), tests spawn a **mock agent script** that:
- Accepts commands on stdin
- Fires hook curls to `http://localhost:${SAM_PORT}/api/hooks` with `SAM_SESSION_ID`
- Outputs PTY text (for permission prompt testing)
- Exits with configurable exit code

The mock agent is a bash script at `test/support/mock_agent.sh`.

### How Mock Agent Is Wired In

1. A test-specific agent adapter `Sam.Agents.Mock` returns `["test/support/mock_agent.sh"]` as the spawn command.
2. The test creates a session via Wallaby, selecting "mock" as the agent type (or the test creates the session programmatically via `GroupSupervisor.start_session` with `command: ["test/support/mock_agent.sh"]`).
3. The Zig PTY port spawns the script, passing `SAM_SESSION_ID` and `SAM_PORT` as env vars.
4. The mock agent reads stdin for commands and fires hook HTTP requests to the correct port.

### Port Configuration

The `sam-hook.sh` and mock agent both need the correct port. The Zig PTY port passes `SAM_PORT` as an env var alongside `SAM_SESSION_ID`. In dev, this defaults to 4000. In test, it's the Wallaby server port. The PTY module reads this from the endpoint config.

### Infrastructure

- **Wallaby** (already in deps) with Chrome driver
- **FeatureCase** (already exists at `test/support/feature_case.ex`)
- **config/test.exs** needs `server: true`
- Tests tagged `@tag :e2e`, excluded by default, run with `mix test --include e2e`

### Test Scenarios

Tests are split into two batches:

**Batch A: Core state machine (tests 1-9)**
Can be written against existing code (some will fail, that's RED phase).

```
1.  Fresh session → badge shows IDLE
2.  Type message + Enter → WORKING within 1 second
3.  PreToolUse hook fires → stays WORKING
4.  PostToolUse hook + wait → IDLE
5.  Long-running tool (10s mock) → stays WORKING throughout
6.  Multiple tools in sequence → stays WORKING
7.  PTY outputs permission prompt → NEEDS INPUT
8.  Mock agent exits 0 → DONE
9.  Mock agent exits 1 → ERROR
```

**Batch B: Subagent tracking (tests 10-15)**
Requires subagent data model and `:background` state implementation.

```
10. Agent PreToolUse → agent row appears in panel as WORKING
11. Agent PostToolUse → agent row shows DONE
12. Multiple agent tools → separate rows in panel
13. Main idle + agents working → BACKGROUND badge
14. Last agent completes → BACKGROUND → IDLE
15. User sends input while BACKGROUND → WORKING
```

### Mock Agent Protocol

The mock agent reads lines from stdin and executes commands:

```
# Trigger a PreToolUse hook:
PRE_TOOL Read /path/to/file

# Trigger a PostToolUse hook:
POST_TOOL Read

# Trigger an Agent PreToolUse:
PRE_TOOL Agent "exploring codebase"

# Trigger an Agent PostToolUse:
POST_TOOL Agent

# Print permission prompt to PTY stdout:
PERMISSION "Allow Read access to /etc/passwd?"

# Sleep (simulate long-running tool):
SLEEP 10

# Exit with code:
EXIT 0
EXIT 1
```

Each `PRE_TOOL` / `POST_TOOL` command fires HTTP POST to `http://localhost:${SAM_PORT}/api/hooks` with JSON payload including `SAM_SESSION_ID`, tool name, and description.

### File Structure

```
test/
  support/
    feature_case.ex          (exists)
    mock_agent.sh            (new — mock Claude Code)
  features/
    status_indicator_test.exs (new — 15 E2E scenarios)
lib/
  sam/agents/
    mock.ex                  (new — test agent adapter)
```

## Implementation Order

1. **Infrastructure** — `server: true` in test config, verify chromedriver, create mock_agent.sh, create Sam.Agents.Mock, add SAM_PORT env var to PTY
2. **Batch A tests RED** — Write tests 1-9, all failing
3. **Fix state machine** — Fix transitions for `:needs_input` → `:working`, terminal state protection
4. **Batch A tests GREEN**
5. **Batch B tests RED** — Write tests 10-15, all failing
6. **Implement subagent tracking + `:background`** — Server changes, template changes
7. **Batch B tests GREEN**
8. **Update CLAUDE.md** — New state machine, `mix test --include e2e` command

## Out of Scope

- TranscriptWatcher / JSONL-based detection (abandoned — hooks are the approach)
- Real Claude Code in E2E tests (mock agent only)
- Subagent nesting (agent spawning agents)
- Status persistence across server restarts
- Unit test coverage for `input_needed?/1` regex variations (existing tests cover this)
