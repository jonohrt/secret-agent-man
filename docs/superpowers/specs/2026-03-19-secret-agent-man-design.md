# Secret Agent Man — Design Spec

> AI coding agent session manager. Mission control for your fleet of coding agents.

## Problem

Running multiple AI coding agents (Claude Code, OpenCode, Codex, Gemini CLI, Copilot) across worktrees means constantly switching terminals, losing track of what each session is doing, and drowning in noisy output. There's no single pane of glass that shows you what's happening across all your sessions in a way that's actually useful.

## Solution

A local web application that provides a real-time, structured dashboard for all running AI coding agent sessions. The primary experience is a summarized, low-noise activity view — not a wall of terminal output. The terminal is available as a fallback, not the default.

## User

Single user, single machine, power user running 3-5 concurrent agent sessions.

## Tech Stack

- **Backend**: Elixir / Phoenix
- **Frontend**: Phoenix LiveView (structured views) + xterm.js (terminal embeds)
- **Process management**: OTP GenServers + Supervisors for session lifecycle
- **Terminal I/O**: PTY spawning via a small C Port program that calls `forkpty()` — the Port program allocates a real PTY, execs the agent process, and relays I/O to the Elixir VM over stdin/stdout. WebSocket bridge to xterm.js via Phoenix Channels.
- **LLM summarization**: Anthropic API (Claude Haiku) via `req` HTTP client
- **Data**: ETS for live session state + DETS for persistence. Session history (activity feed, summaries) is periodically flushed to DETS so it survives application restarts. On startup, the app checks for orphaned agent processes and reconnects.

## Supported Agents

Day-one support:
- Claude Code
- OpenCode
- Codex CLI
- Gemini CLI
- GitHub Copilot CLI

Adding a new agent requires: a spawn command, and optionally a hook integration module. Agents without hooks fall back to stream parsing + LLM summarization.

## Architecture

### Process Tree

```
Application Supervisor
├── SessionRegistry (GenServer)
│   └── Tracks all active sessions by ID, ETS-backed
├── SessionSupervisor (DynamicSupervisor)
│   └── Spawns per-session Supervisors:
│       └── Session.GroupSupervisor (Supervisor, rest_for_one)
│           ├── Session.PTY (GenServer) — owns the C Port PTY, raw I/O
│           ├── Session.Parser (GenServer) — output parsing, event extraction
│           ├── Session.Summarizer (GenServer) — LLM summarization
│           └── Session.Server (GenServer) — lifecycle, state, metadata
│           # rest_for_one: if PTY dies, Parser/Summarizer/Server restart.
│           # If Summarizer dies, only Server restarts (state refresh).
│           # PTY crash does NOT lose the underlying agent process — the C
│           # Port program keeps the PTY open; we reconnect on restart.
├── Hook.Receiver (Phoenix endpoint: POST /api/hooks)
│   └── Receives structured JSON events from Claude Code hooks via curl
├── Phoenix.Endpoint
│   ├── LiveView: DashboardLive — main tab-bar UI
│   ├── LiveView: SessionLive — individual session detail
│   └── Channel: TerminalChannel — xterm.js WebSocket bridge
└── Persistence.Writer (GenServer)
    └── Periodically flushes ETS session state to DETS
```

### Data Flow

```
Agent PTY → raw bytes → Session.PTY
  → Session.Parser (extracts structured events: tool calls, file edits, agent spawns)
  → Session.Summarizer (LLM compresses activity between decision points)
  → Session.Server (updates session state)
  → LiveView (pushes real-time updates to browser)

xterm.js ↔ Phoenix Channel ↔ Session.PTY (bidirectional for terminal mode)
```

## UI Layout

### Tab Bar (top)

Horizontal tabs, one per session. Each tab shows:
- **Status dot** — color-coded (green=working, yellow=needs input, gray=idle/done, red=error)
- **Session name** — project or task name
- **Branch name** — abbreviated, secondary text
- **+ button** — create new session

Active tab has an accent-colored bottom border.

### Main Panel (below tabs, split into two columns)

**Left column — Activity Feed:**
- Current status badge (Working / Needs Input / Idle / Error / Done)
- Current task description (from initial prompt or latest instruction)
- Chronological activity feed — **decision-point summaries**, not raw output
  - Each entry: timestamp + summarized action ("Searched codebase for auth handler → found in src/auth/middleware.ts")
  - LLM-generated, compressing noisy tool call sequences into conclusions
  - Expandable: click to see the raw actions underneath if needed

**Right column — Agents + Context:**
- **Agent list**: each subagent shown as a card with:
  - Name/description
  - Status indicator
  - Current task summary
  - Clickable → expands to show that agent's activity feed
- **Git changes** (nice-to-have): files added/modified/deleted, insertions/deletions count
- **Token usage** (nice-to-have, low priority): running cost estimate
- **Time elapsed** (nice-to-have): session duration

### Interaction

**When session status is "needs input":**
- Quick-action buttons appear for common responses (approve, deny, yes, no)
- Inline text input bar for typed responses — piped to agent's stdin
- "Open Terminal" button for complex interaction → switches to full xterm.js view

**Terminal view:**
- Full xterm.js terminal embed showing the raw agent session
- Keyboard shortcut (Esc) or button to return to structured view
- Terminal is always running underneath — structured view is an overlay, not a replacement

### New Session Dialog

- Select agent type (Claude Code, OpenCode, Codex, Gemini CLI, Copilot)
- Select or create worktree/directory
- Enter initial prompt/task description
- Optional: select project profile (predefined configs)

## Output Parsing — Hybrid Approach

### Tier 1: Hook-based (Claude Code)

Claude Code supports hooks — shell commands that fire on events (tool calls, completions, errors). We register hooks that POST structured JSON to our backend at `http://localhost:4000/api/hooks`:

```bash
# Example hook in ~/.claude/settings.json
# The hook script POSTs event data via curl:
curl -s -X POST http://localhost:4000/api/hooks \
  -H "Content-Type: application/json" \
  -d '{"event":"tool_call","tool":"Edit","file":"src/auth.ts","session_id":"$SESSION_ID"}'
```

The `Hook.Receiver` Phoenix controller receives these, routes them to the correct Session.Parser by session ID, and they flow through the normal event pipeline.

**Hook registration**: On first launch, the app checks `~/.claude/settings.json` for SAM hooks. If missing, it prompts the user to approve adding them. Hooks are non-destructive (additive to existing hooks).

This gives us clean, structured events with zero parsing.

### Tier 2: Stream Parsing (agents with structured output)

For agents that emit recognizable patterns (e.g., markdown tool call blocks, status lines), we pattern-match the PTY output stream. Fragile but workable for known formats.

### Tier 3: LLM Summarization (universal fallback)

For any agent, we can feed chunks of raw output to Haiku and ask for:
- Current status (working/waiting/done/error)
- What just happened (structured summary)
- Whether input is needed

This is the universal adapter. More expensive but works for any agent regardless of output format.

### Decision-Point Detection

A "decision point" is when the agent pauses between phases of work. Detection varies by tier:

- **Tier 1 (hooks)**: Hook events explicitly signal decision points — tool call completion, agent spawn, task completion, permission request.
- **Tier 2 (stream parsing)**: Pattern-match known prompts (e.g., `? Allow`, `[y/N]`, `Press enter`). Also detect output quiescence — if no new output for 3+ seconds after a burst of activity, treat as a decision point.
- **Tier 3 (LLM)**: Feed the last N seconds of buffered output to Haiku and ask: "Is the agent waiting for input, actively working, or done? Summarize what just happened." Debounce to at most 1 call per 10 seconds per session to control cost.

### Decision-Point Summarization

The core noise-reduction feature. The Summarizer watches the event stream and:

1. Buffers events between decision points (as detected above)
2. When a decision point is reached, sends the buffered events to Haiku: "Summarize what happened in this sequence of actions in one sentence. Focus on the outcome, not the process."
3. The summary replaces the raw event sequence in the activity feed
4. Raw events are preserved and viewable on expand
5. Summaries are debounced — at most 1 LLM call per 5 seconds per session. Pending events accumulate and get summarized in the next batch.

## Theming

### Architecture

Themes are defined as a set of CSS custom properties + a small metadata config:

```css
/* Theme via CSS custom properties — each theme is a CSS class on <body> */
body.theme-tron {
  --bg-primary: #0a0a1a;
  --bg-secondary: #12122a;
  --accent: #00ffff;
  --accent-glow: rgba(0, 255, 255, 0.3);
  --text-primary: #e0e0e0;
  --text-secondary: #888888;
  --status-working: #00ff00;
  --status-input: #ffcc00;
  --status-idle: #666666;
  --status-error: #ff4444;
  --border: rgba(0, 255, 255, 0.2);
  --scanlines: block;  /* display value for scanline overlay */
  --glow-intensity: 1;
}
```

Theme switching is pure client-side — swap the CSS class on `<body>`, stored in localStorage. No server-side theme infrastructure needed.

### Built-in Themes

1. **Tron** (default) — Cyan on black, scanlines, glowing accents
2. **Synthwave** — Hot pink / purple neon, gradient backgrounds
3. **Phosphor** — Green on black, military/Fallout terminal feel
4. **Amber** — Classic amber CRT monochrome

### Custom Themes

Users can create custom themes by adding CSS files to `~/.config/secret-agent-man/themes/` that override the CSS custom properties. No hot-reload infrastructure needed for v1 — a page refresh picks up new themes.

## Session Creation

### Launched from UI (primary, v1)

User clicks "+", fills out the new session dialog. Backend spawns the agent process in a real PTY via the C Port program, wraps it in the session process group. Full control from the start — hooks registered, output parsed, terminal accessible.

### Future: External session attachment (v2, research needed)

Attaching to an already-running agent's PTY from another process is not feasible without OS-level tricks (ptrace, reptyr) that macOS SIP blocks. Potential v2 approaches:
- **tmux-based**: If agents are launched inside tmux, we can `tmux capture-pane` and `tmux send-keys` to observe/interact without PTY attachment.
- **Wrapper script**: Provide a `sam-launch` wrapper that users run instead of `claude` directly — it spawns the agent inside a SAM-managed PTY and registers with the dashboard.

For v1, all sessions must be launched from the UI.

## Session Lifecycle

```
Created → Starting → Running → (Needs Input ↔ Running) → Done
                                                        → Error
```

- **Created**: session config defined, process not yet spawned
- **Starting**: PTY process spawning
- **Running**: agent is actively working
- **Needs Input**: agent is waiting for user response (detected via hooks or output parsing)
- **Done**: agent completed its task
- **Error**: agent crashed or encountered an unrecoverable error

Sessions can be manually interrupted (send SIGINT) or killed (SIGTERM) from the UI. Note: interrupt behavior varies by agent — Claude Code handles SIGINT gracefully, others may not.

### Shutdown Behavior

- **Browser tab closed**: Agent processes keep running. Dashboard reconnects on next visit.
- **Phoenix server stopped**: Agent processes spawned via the C Port program receive SIGHUP when the Port closes. The Port program is designed to keep the child alive by default — on restart, the app reads DETS for session metadata and attempts to re-adopt orphaned processes by PID.
- **Agent process exits**: Session transitions to Done (exit 0) or Error (non-zero). PTY Port detects EOF and notifies Session.Server.

## ANSI Handling

Agent CLIs emit heavy ANSI escape sequences (colors, cursor movement, alternate screen buffer). Two separate concerns:

- **Terminal view (xterm.js)**: xterm.js handles all ANSI natively — no processing needed. Raw PTY bytes flow through the Channel directly.
- **Structured view (Parser)**: The Parser strips ANSI sequences before extracting events. Use a library like `ansi_to_html` for any cases where we want to preserve formatting in the activity feed, but default to plain text summaries.

The Parser maintains a virtual terminal state (tracking cursor position, screen content) only if needed for agents that use alternate screen buffer or cursor-addressed output. For v1, simple line-buffered output with ANSI stripping is sufficient.

## Asset Bundling

xterm.js is an npm package. Phoenix's default esbuild setup doesn't include npm. We use npm in the `assets/` directory:

- `assets/package.json` declares `xterm`, `xterm-addon-fit`, `xterm-addon-webgl` as dependencies
- `assets/js/terminal.js` imports xterm and connects to the Phoenix Channel
- esbuild bundles everything into `priv/static/assets/app.js`

This is the standard Phoenix approach for JS dependencies beyond what esbuild alone provides.

## Project Structure

```
secret-agent-man/
├── c_src/
│   └── pty_port.c                    # C Port program: forkpty() + I/O relay
├── lib/
│   ├── sam/                          # Core application
│   │   ├── application.ex            # OTP application + supervisor tree
│   │   ├── session/
│   │   │   ├── registry.ex           # Session registry (ETS-backed)
│   │   │   ├── group_supervisor.ex   # Per-session Supervisor (rest_for_one)
│   │   │   ├── server.ex             # Per-session GenServer (state, lifecycle)
│   │   │   ├── pty.ex                # PTY process management (wraps C Port)
│   │   │   ├── parser.ex             # Output parsing (hooks + patterns + ANSI strip)
│   │   │   └── summarizer.ex         # LLM decision-point summarization
│   │   ├── agents/
│   │   │   ├── behaviour.ex          # Agent behaviour (spawn cmd, detect patterns)
│   │   │   └── claude_code.ex        # Claude Code adapter (hook-based)
│   │   ├── persistence.ex            # ETS ↔ DETS flush + orphan recovery
│   │   └── llm/
│   │       └── client.ex             # Anthropic API client (req-based)
│   ├── sam_web/                      # Phoenix web layer
│   │   ├── live/
│   │   │   └── dashboard_live.ex     # Main dashboard (tabs + panels + new session)
│   │   ├── channels/
│   │   │   └── terminal_channel.ex   # xterm.js WebSocket bridge
│   │   ├── controllers/
│   │   │   └── hook_controller.ex    # POST /api/hooks receiver
│   │   └── layouts/
│   │       └── root.html.heex        # Root layout with theme CSS vars
│   └── sam_web.ex
├── assets/
│   ├── package.json                  # npm deps: xterm, xterm-addon-fit, etc.
│   ├── js/
│   │   ├── app.js
│   │   └── terminal.js               # xterm.js setup + channel connection
│   └── css/
│       └── app.css                   # Base styles + theme CSS custom properties
├── config/
│   ├── config.exs
│   ├── dev.exs
│   └── runtime.exs                   # API keys, theme config
├── mix.exs
└── Makefile                          # Compiles c_src/pty_port.c
```

Note: Only `claude_code.ex` adapter is listed — other agent adapters (opencode, codex, gemini, copilot) are structurally identical and will be added as needed. No premature files.

## Key Dependencies

```elixir
# mix.exs
defp deps do
  [
    {:phoenix, "~> 1.7"},
    {:phoenix_live_view, "~> 1.0"},
    {:phoenix_html, "~> 4.0"},
    {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
    {:req, "~> 0.5"},              # HTTP client for Anthropic API
    {:jason, "~> 1.4"}             # JSON encoding/decoding
  ]
end
```

Minimal dependency set. The C Port program (`pty_port.c`) is compiled via `make` and has no external dependencies beyond POSIX `<pty.h>`.

## Acceptance Verification

### Automated Checks

1. **PTY spike**: Compile `pty_port.c`, spawn a shell via Elixir Port, send a command, read output — proves the PTY layer works
2. **Session spawn**: Launch Claude Code from UI → verify PTY process exists, session appears in tab bar within 2s
3. **Activity summarization**: Trigger a multi-step agent task → verify activity feed shows summarized entries (not raw tool calls)
4. **Terminal embed**: Click "Open Terminal" → verify xterm.js connects and shows live agent output, keyboard input reaches the agent
5. **Theme switching**: Change theme via UI → verify all CSS variables update, no visual artifacts
6. **Needs-input detection (hook-based)**: Claude Code reaches a permission prompt → verify status changes to "needs input" within 3s via hook event, quick-action buttons appear
7. **Multi-session**: Run 3 concurrent sessions → verify all tabs show correct independent status and activity

### Verification Access

- Dashboard: `http://localhost:4000`
- Health check: `http://localhost:4000/api/health` (returns session count, uptime)
- Session state: `http://localhost:4000/api/sessions` (JSON dump of all session state for debugging)

### Success Threshold

- All 7 automated checks pass
- Activity feed entries are ≤2 sentences each (no raw noise)
- Tab status updates within 3s of actual agent state change (hook-based agents); ≤15s for stream-parsed agents
- Terminal embed has <100ms input latency
- Theme switch is instant (no page reload)
