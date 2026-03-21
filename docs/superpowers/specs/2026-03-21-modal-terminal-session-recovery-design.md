# Design: Modal Terminal + Session Recovery (Ghost Tabs)

**Date:** 2026-03-21
**Branch:** feature/blue-steel-ui
**Status:** Approved
**Beads:** secret-agent-man-bec, secret-agent-man-c95

---

## Feature 1: Modal Terminal per Session

### Purpose

Full-screen terminal modal in the session's workdir for quick shell access — git commands, neovim, file browsing. Separate from the agent's PTY so there's no interference.

### Architecture

- `SamWeb.Components.TerminalModal` (LiveComponent) — full-screen modal overlay with xterm.js
- Spawns a standalone PTY (`/bin/zsh` or `$SHELL`) in the session's workdir via `Sam.Session.PTY`
- Separate Phoenix channel (`SamWeb.AuxTerminalChannel`) for I/O — does not share the agent's channel
- PTY is NOT in the GroupSupervisor tree — started/stopped by the LiveView to avoid coupling with agent lifecycle

### UX

- **Toggle:** TERMINAL button in the status bar (repurpose existing "SHOW TTY" button). Close via the X button on the modal. No Escape shortcut — conflicts with vim/neovim.
- **Modal:** covers ~95% viewport, dark CRT themed, centered with slight border glow
- **Lifecycle:** PTY spawned on first open, stays alive while session exists. Killed when session terminates or user explicitly closes.
- **Multiple sessions:** each session gets its own aux terminal. Switching sessions hides the current modal and shows the other session's aux terminal on next toggle.

### Components

**SamWeb.Components.TerminalModal (LiveComponent):**
- `lib/sam_web/components/terminal_modal.ex`
- Attrs: `session_id`, `workdir`, `visible`
- Renders a modal overlay with a div for xterm.js (phx-hook="AuxTerminal")
- Does not manage the PTY itself — that's the channel's job

**AuxTerminal JS Hook:**
- `assets/js/aux_terminal.js`
- Creates xterm.js Terminal instance on mount
- Connects to `AuxTerminalChannel` with `{session_id}`
- Handles input → channel push, channel output → terminal write
- Handles resize → channel push

**SamWeb.AuxTerminalChannel:**
- `lib/sam_web/channels/aux_terminal_channel.ex`
- On join: spawn a PTY process (plain shell, no Claude Code) in the session's workdir
- Route input/output between channel and PTY
- On leave/terminate: kill the PTY

**PTY Spawning:**
- Reuse `Sam.Session.PTY.start_link/1` with a shell command instead of Claude Code
- Command: `[System.get_env("SHELL") || "/bin/zsh"]`
- Workdir: session's workdir
- The PTY process is linked to the channel process — channel dies, PTY dies

### CSS

- Modal overlay: `position: fixed; inset: 0; z-index: 1000; background: rgba(0,0,0,0.9)`
- Terminal container: `width: 95vw; height: 90vh; margin: auto; border: 1px solid var(--phosphor-green); border-radius: 8px`
- CRT glow effect on the border

---

## Feature 2: Session Recovery (Ghost Tabs)

### Purpose

After SAM restarts, show previously running sessions as ghost tabs so the user can see what they had and one-click restart.

### Architecture

- `Sam.Persistence` already saves session metadata to DETS every 30s
- On startup: `load_sessions()` reads DETS, checks which sessions have running processes via Registry
- Sessions without running processes render as ghost tabs (grayed out, `:disconnected` status)
- Click ghost tab → restart session with saved params

### Data Flow

**On session create (existing):**
`Sam.Persistence` flushes `{session_id, %{name, workdir, agent_type, status, activity}}` to DETS every 30s.

**On SAM startup:**
1. `DashboardLive.mount` calls `load_sessions()` which queries the Registry for running sessions
2. NEW: also call `Sam.Persistence.load_saved_sessions()` to get DETS entries
3. For each DETS entry not in the running set → add as ghost session with `status: :disconnected`
4. Ghost sessions rendered in tab bar with grayed-out styling

**On ghost tab click:**
1. `handle_event("restart_session", %{"id" => id}, socket)`
2. Read saved params from ghost session data
3. Call `create_session` with `{name, workdir, agent_type}`
4. Remove ghost entry, add live session

**On explicit terminate/kill:**
1. Remove from DETS via `Sam.Persistence.delete_session(session_id)`
2. Prevents ghost on next restart (clean shutdown = no ghost)

### Components

**Sam.Persistence (modified):**
- Add `load_saved_sessions()` — reads all DETS entries, returns list of session maps
- Add `delete_session(session_id)` — removes entry from DETS

**DashboardLive (modified):**
- `mount`: merge running sessions + saved ghost sessions
- `handle_event("restart_session")`: restart from ghost params
- `handle_event("dismiss_ghost")`: remove ghost without restarting
- Tab bar: ghost tabs styled with `status-dot disconnected` class + "RESTART" label

### CSS

- `.status-dot.disconnected`: gray with reduced opacity, no glow
- `.sam-tab.ghost`: reduced opacity, dashed border or similar visual distinction

### Edge Cases

- DETS entry exists but session is already running → skip (not a ghost)
- DETS file doesn't exist (fresh install) → no ghosts, normal behavior
- Multiple SAM instances → not supported, DETS is single-writer
- Ghost session's workdir no longer exists → show ghost but disable restart with tooltip

---

## Testing Strategy

### Modal Terminal Tests
- **Unit:** TerminalModal component renders with visible/hidden states
- **Unit:** AuxTerminalChannel joins and spawns PTY
- **Unit:** AuxTerminalChannel forwards input/output
- **Unit:** AuxTerminalChannel kills PTY on leave

### Session Recovery Tests
- **Unit:** `Persistence.load_saved_sessions/0` returns saved session data
- **Unit:** `Persistence.delete_session/1` removes entry
- **Unit:** DashboardLive shows ghost tabs for saved-but-not-running sessions
- **Unit:** Clicking ghost tab restarts session with correct params
- **Unit:** Terminating a session removes it from DETS

## No New Dependencies

Both features use existing infrastructure: xterm.js, Phoenix channels, Sam.Session.PTY, DETS.
