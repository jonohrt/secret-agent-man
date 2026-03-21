# Secret Agent Man (SAM)

Local web dashboard for managing multiple AI coding agent sessions. Elixir/Phoenix LiveView + Zig PTY port + xterm.js. Retro 80s CRT aesthetic.

## Workflow

- **TDD is mandatory.** No production code without a failing test first. Use the `superpowers:test-driven-development` skill.
- **Brainstorm before building.** Use the `superpowers:brainstorming` skill before any feature work or non-trivial bugfix.
- **Use Tidewave** (`mcp__tidewave__project_eval`) to inspect live process state when debugging — don't guess.
- **Verify before claiming done.** Run `mix precommit` before finishing any task.
- **End-to-end verification is required.** Unit tests and tidewave evals are not enough. Every user-facing change must be verified with: fresh server restart → create/use session through UI → screenshot result. Use `mcp__screenshot-website-fast__take_screenshot` for visual verification.

## Verification Checklist (before claiming any feature works)

1. `mix precommit` passes (compile, format, test)
2. Restart Phoenix server (`mix phx.server`) — GenServers keep old code otherwise
3. Test the actual user flow in the browser (create session, interact, observe)
4. Screenshot to prove it works visually
5. **Do NOT verify via tidewave eval alone** — it runs in your session context, not the spawned session's

## Test Commands

```bash
mix test                              # Run all tests (E2E excluded by default)
mix test --include e2e                # Run ALL tests including E2E browser tests (requires chromedriver)
mix test test/features/               # Run only E2E tests
mix test test/sam/session/server_test.exs  # Run specific test file
mix test --failed                     # Re-run failures
mix precommit                         # Full check: compile --warnings-as-errors, format, test
```

## Test Conventions

- Use `start_supervised!/1` to start processes — guarantees cleanup between tests
- **Never use `Process.sleep/1`** in tests — use `assert_receive` with timeouts or `:sys.get_state/1` for synchronization
- Use `Process.monitor/1` + `assert_receive {:DOWN, ...}` for process termination
- Pass short timer values in tests (e.g., `quiescence_ms: 100`) to avoid slow tests
- Use unique session IDs per test: `"test-#{System.unique_integer([:positive])}"`
- Tests that start real processes (PTY, GroupSupervisor) must be `async: false`
- Pure function tests can be `async: true`
- **Consider E2E tests** for user-facing features (see Known Issues below)

## Architecture

PubSub-driven process tree per session, supervised with `rest_for_one`:

```
GroupSupervisor (one per session)
  -> Server             (status state machine, PubSub routing)
  -> Summarizer         (LLM-powered activity summaries)
  -> Parser             (PTY output -> structured events)
  -> TranscriptWatcher  (JSONL transcript -> tool_call/tool_result events)
  -> PTY                (Zig port, raw I/O)
```

### PubSub Topics
- `"session:#{id}"` — PTY output, parser events, summaries
- `"session_input:#{id}"` — input/resize/kill commands
- `"sessions:ui"` — UI updates for LiveView

### Status State Machine
```
:idle -> :working <-> :idle
            |
        :background (main idle, subagents still running)
            |
          :idle (last subagent completes)

:idle/:working -> :needs_input -> :working (user responds)
:any -> :done (exit 0) | :error (exit non-zero)
```

Status is driven by **Claude Code hooks** (PreToolUse/PostToolUse) firing HTTP requests to SAM's `/api/hooks` endpoint. The PTY port passes `SAM_SESSION_ID` and `SAM_PORT` as env vars so hooks can identify the session. User pressing Enter also triggers `:working` immediately via `send_input` detection.

## Key Files

- `lib/sam/session/server.ex` — Status management, PubSub routing, UTF-8 sanitization
- `lib/sam/session/parser.ex` — PTY output parsing, activity/input detection
- `lib/sam/session/transcript_watcher.ex` — JSONL transcript file watcher for status
- `lib/sam/session/pty.ex` — Zig PTY port wrapper
- `lib/sam/session/summarizer.ex` — LLM activity summarization
- `lib/sam_web/live/dashboard_live.ex` — Main LiveView
- `assets/js/terminal.js` — xterm.js hook
- `assets/css/themes.css` — 4 themes with CSS custom properties

## Known Issues

### Status indicator not working end-to-end
TranscriptWatcher exists but can't reliably find the correct JSONL file for SAM-spawned Claude Code sessions. The watcher picks the most recently modified `.jsonl` in `~/.claude/projects/<dir>/`, but that may be a different session's file. Need to either:
1. Pass SAM's session ID as an env var to Claude Code so the JSONL filename is predictable
2. Watch for new JSONL files created after session start (file creation time > session start time)
3. Study how pixel-agents (github.com/pablodelucca/pixel-agents) maps terminals to JSONL files

Reference: Claude Code JSONL files live at `~/.claude/projects/<encoded-workdir>/<uuid>.jsonl` with records like `{type: "assistant", message: {content: [{type: "tool_use", name: "Read"}]}}`.

### UTF-8 safety
All strings reaching LiveView/Jason must be valid UTF-8. Key gotcha: Elixir regexes without `/u` flag corrupt multi-byte characters. Always use `~r/.../u` when pattern or input contains non-ASCII.

### E2E testing gap
No automated E2E tests exist. Unit tests pass but don't catch real integration issues (wrong JSONL file, stale GenServer code, hot-reload gaps). Consider adding Wallaby or similar for browser-based E2E tests.
