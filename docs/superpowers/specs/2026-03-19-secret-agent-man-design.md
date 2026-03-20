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
- **Terminal I/O**: PTY spawning via Elixir Ports (using `script -q /dev/null` or `exile` for PTY allocation), WebSocket bridge to xterm.js via Phoenix Channels
- **LLM summarization**: Anthropic API (Claude Haiku) via `req` HTTP client
- **Data**: In-memory (ETS) for session state, no database needed

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
│   └── Tracks all active sessions by ID
├── SessionSupervisor (DynamicSupervisor)
│   └── Per-session process group:
│       ├── Session.Server (GenServer) — lifecycle, state, metadata
│       ├── Session.PTY (GenServer) — owns the PTY Port, raw I/O
│       ├── Session.Parser (GenServer) — output parsing, event extraction
│       └── Session.Summarizer (GenServer) — LLM summarization of activity
├── Discovery.Watcher (GenServer)
│   └── Watches for externally-launched agent processes, auto-attaches
├── Phoenix.Endpoint
│   ├── LiveView: DashboardLive — main tab-bar UI
│   ├── LiveView: SessionLive — individual session detail
│   └── Channel: TerminalChannel — xterm.js WebSocket bridge
└── Theme.Server (GenServer)
    └── Loads and serves theme configs
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
- **Status dot** — color-coded (green=working, yellow=needs input, blue=working, gray=idle/done, red=error)
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

Claude Code supports hooks — shell commands that fire on events (tool calls, completions, errors). We register hooks that emit structured JSON to our backend via HTTP POST or Unix socket:

```json
{"event": "tool_call", "tool": "Edit", "file": "src/auth.ts", "session_id": "abc123"}
{"event": "agent_spawn", "description": "Test writer", "session_id": "abc123"}
{"event": "completion", "session_id": "abc123"}
```

This gives us clean, structured events with zero parsing.

### Tier 2: Stream Parsing (agents with structured output)

For agents that emit recognizable patterns (e.g., markdown tool call blocks, status lines), we pattern-match the PTY output stream. Fragile but workable for known formats.

### Tier 3: LLM Summarization (universal fallback)

For any agent, we can feed chunks of raw output to Haiku and ask for:
- Current status (working/waiting/done/error)
- What just happened (structured summary)
- Whether input is needed

This is the universal adapter. More expensive but works for any agent regardless of output format.

### Decision-Point Summarization

The core noise-reduction feature. The Summarizer watches the event stream and:

1. Buffers events between "decision points" (moments where the agent pauses, asks for input, completes a subtask, or changes direction)
2. When a decision point is reached, sends the buffered events to Haiku with a prompt like: "Summarize what happened in this sequence of actions in one sentence. Focus on the outcome, not the process."
3. The summary replaces the raw event sequence in the activity feed
4. Raw events are preserved and viewable on expand

## Theming

### Architecture

Themes are defined as a set of CSS custom properties + a small metadata config:

```elixir
# Theme config (loaded from TOML files)
%Theme{
  name: "tron",
  display_name: "Tron / CRT",
  colors: %{
    bg_primary: "#0a0a1a",
    bg_secondary: "#12122a",
    accent: "#00ffff",
    accent_glow: "rgba(0, 255, 255, 0.3)",
    text_primary: "#e0e0e0",
    text_secondary: "#888888",
    status_working: "#00ff00",
    status_input: "#ffcc00",
    status_idle: "#666666",
    status_error: "#ff4444",
    status_done: "#888888",
    border: "rgba(0, 255, 255, 0.2)",
    diff_add: "#00ff00",
    diff_modify: "#ffcc00",
    diff_delete: "#ff4444"
  },
  effects: %{
    scanlines: true,
    glow: true,
    crt_curve: false
  }
}
```

### Built-in Themes

1. **Tron** (default) — Cyan on black, scanlines, glowing accents
2. **Synthwave** — Hot pink / purple neon, gradient backgrounds
3. **Phosphor** — Green on black, military/Fallout terminal feel
4. **Amber** — Classic amber CRT monochrome

### Custom Themes

Users drop a `.toml` file in `~/.config/secret-agent-man/themes/`. The app watches this directory and hot-reloads.

## Session Discovery

### Launched from UI

User clicks "+", fills out the new session dialog. Backend spawns the agent process in a PTY, wraps it in the session process group. Full control from the start.

### Auto-discovery of existing sessions

The Discovery.Watcher process periodically scans for running agent processes:
- `pgrep -f "claude"` / `pgrep -f "opencode"` etc.
- Checks if the process is already tracked
- For untracked processes, attempts to attach by:
  1. Identifying the working directory (`lsof -p PID` or `/proc/PID/cwd`)
  2. Reading the git branch from that directory
  3. Creating a Session.Server with limited capabilities (can observe via PTY attach, but hooks may not be registered)
  4. Starting LLM summarization on the output stream

Discovered sessions get a "discovered" badge and may have reduced functionality (no hook events, summarization-only activity feed).

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

Sessions can be manually paused (send Ctrl+C), resumed, or killed from the UI.

## Project Structure

```
secret-agent-man/
├── lib/
│   ├── sam/                          # Core application
│   │   ├── application.ex            # OTP application + supervisor tree
│   │   ├── session/
│   │   │   ├── registry.ex           # Session registry (ETS-backed)
│   │   │   ├── supervisor.ex         # DynamicSupervisor for sessions
│   │   │   ├── server.ex             # Per-session GenServer
│   │   │   ├── pty.ex                # PTY process management
│   │   │   ├── parser.ex             # Output parsing (hooks + patterns)
│   │   │   └── summarizer.ex         # LLM summarization
│   │   ├── agents/
│   │   │   ├── behaviour.ex          # Agent behaviour (spawn, detect, parse)
│   │   │   ├── claude_code.ex        # Claude Code adapter (hooks)
│   │   │   ├── opencode.ex           # OpenCode adapter
│   │   │   ├── codex.ex              # Codex CLI adapter
│   │   │   ├── gemini.ex             # Gemini CLI adapter
│   │   │   └── copilot.ex            # Copilot CLI adapter
│   │   ├── discovery/
│   │   │   └── watcher.ex            # Process discovery
│   │   ├── themes/
│   │   │   └── server.ex             # Theme loading + hot-reload
│   │   └── llm/
│   │       └── client.ex             # Anthropic API client
│   ├── sam_web/                      # Phoenix web layer
│   │   ├── live/
│   │   │   ├── dashboard_live.ex     # Main dashboard (tab bar + panels)
│   │   │   ├── session_live.ex       # Session detail view
│   │   │   └── new_session_live.ex   # New session dialog
│   │   ├── channels/
│   │   │   └── terminal_channel.ex   # xterm.js WebSocket bridge
│   │   ├── components/
│   │   │   ├── tab_bar.ex            # Tab bar component
│   │   │   ├── activity_feed.ex      # Activity feed component
│   │   │   ├── agent_list.ex         # Agent list component
│   │   │   ├── git_changes.ex        # Git diff component
│   │   │   └── terminal.ex           # xterm.js wrapper component
│   │   └── layouts/
│   │       └── root.html.heex        # Root layout with theme CSS vars
│   └── sam_web.ex
├── assets/
│   ├── js/
│   │   ├── app.js
│   │   └── terminal.js               # xterm.js setup + channel connection
│   └── css/
│       ├── app.css                    # Base styles
│       └── themes/
│           ├── tron.css               # Tron theme variables
│           ├── synthwave.css          # Synthwave theme variables
│           ├── phosphor.css           # Phosphor theme variables
│           └── amber.css              # Amber theme variables
├── config/
│   ├── config.exs
│   ├── dev.exs
│   └── runtime.exs                   # API keys, theme dir, etc.
├── priv/
│   └── themes/                       # Built-in theme TOML files
├── mix.exs
└── README.md
```

## Key Dependencies

```elixir
# mix.exs
defp deps do
  [
    {:phoenix, "~> 1.7"},
    {:phoenix_live_view, "~> 1.0"},
    {:phoenix_html, "~> 4.0"},
    {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
    {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
    {:req, "~> 0.5"},              # HTTP client for Anthropic API
    {:jason, "~> 1.4"},            # JSON encoding/decoding
    {:toml, "~> 0.7"},             # Theme config parsing
    {:file_system, "~> 1.0"},      # File watching (theme hot-reload)
    {:exile, "~> 0.10"}            # PTY/process I/O (alternative to raw Ports)
  ]
end
```

## Acceptance Verification

### Automated Checks

1. **Session spawn**: Launch Claude Code from UI → verify PTY process exists, session appears in tab bar within 2s
2. **Auto-discovery**: Start `claude` in a separate terminal → verify it appears in the dashboard within 10s
3. **Activity summarization**: Trigger a multi-step agent task → verify activity feed shows summarized entries (not raw tool calls)
4. **Terminal embed**: Click "Open Terminal" → verify xterm.js connects and shows live agent output, keyboard input reaches the agent
5. **Theme switching**: Change theme via UI → verify all CSS variables update, no visual artifacts
6. **Needs-input detection**: Agent reaches a permission prompt → verify status changes to "needs input" within 3s, quick-action buttons appear
7. **Multi-session**: Run 3 concurrent sessions → verify all tabs show correct independent status and activity

### Verification Access

- Dashboard: `http://localhost:4000`
- Health check: `http://localhost:4000/api/health` (returns session count, uptime)
- Session state: `http://localhost:4000/api/sessions` (JSON dump of all session state for debugging)

### Success Threshold

- All 7 automated checks pass
- Activity feed entries are ≤2 sentences each (no raw noise)
- Tab status updates within 3s of actual agent state change
- Terminal embed has <100ms input latency
- Theme switch is instant (no page reload)
