# Modal Terminal + Session Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a full-screen modal terminal for shell access in each session's workdir, and ghost tab session recovery on SAM restart.

**Architecture:** Modal terminal uses a new AuxTerminalChannel + JS hook + LiveComponent. The channel spawns a standalone PTY (shell) linked to itself. Session recovery extends Persistence to store workdir/agent_type and loads ghost sessions at mount.

**Tech Stack:** Elixir/Phoenix Channels, xterm.js, Zig PTY port, DETS

---

## File Map

### New Files
| File | Responsibility |
|------|---------------|
| `assets/js/aux_terminal.js` | JS hook: xterm.js instance for modal terminal |
| `lib/sam_web/channels/aux_terminal_channel.ex` | Channel: spawns shell PTY, routes I/O |
| `lib/sam_web/components/terminal_modal.ex` | LiveComponent: full-screen modal overlay |

### Modified Files
| File | Changes |
|------|---------|
| `lib/sam_web/channels/user_socket.ex` | Add `aux_terminal:*` channel route |
| `assets/js/app.js` | Import and register AuxTerminal hook |
| `lib/sam_web/live/dashboard_live.ex` | Add terminal modal toggle, ghost tab rendering, restart handler |
| `lib/sam/persistence.ex` | Add `load_saved_sessions/0`, `delete_session/1`, persist workdir/agent_type |
| `assets/css/app.css` | Modal terminal CSS, ghost tab CSS |

---

### Task 1: AuxTerminalChannel

**Files:**
- Create: `lib/sam_web/channels/aux_terminal_channel.ex`
- Modify: `lib/sam_web/channels/user_socket.ex:4`

- [ ] **Step 1: Write the channel**

```elixir
# lib/sam_web/channels/aux_terminal_channel.ex
defmodule SamWeb.AuxTerminalChannel do
  use Phoenix.Channel
  require Logger

  @impl true
  def join("aux_terminal:" <> session_id, %{"workdir" => workdir}, socket) do
    shell = System.get_env("SHELL") || "/bin/zsh"

    {:ok, pty_pid} =
      Sam.Session.PTY.start_link(%{
        session_id: "aux-#{session_id}",
        command: [shell],
        workdir: workdir
      })

    # Link so PTY dies when channel dies
    Process.link(pty_pid)

    # Subscribe to aux PTY output
    Phoenix.PubSub.subscribe(Sam.PubSub, "session:aux-#{session_id}")

    {:ok, assign(socket, pty_pid: pty_pid, session_id: session_id)}
  end

  @impl true
  def handle_in("input", %{"data" => data}, socket) do
    Sam.Session.PTY.send_input(socket.assigns.pty_pid, data)
    {:noreply, socket}
  end

  @impl true
  def handle_in("resize", %{"cols" => cols, "rows" => rows}, socket) do
    Sam.Session.PTY.resize(socket.assigns.pty_pid, cols, rows)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:pty_output, _session_id, data}, socket) do
    push(socket, "output", %{data: Base.encode64(data)})
    {:noreply, socket}
  end

  def handle_info({:pty_exit, _session_id, _code}, socket) do
    {:stop, :normal, socket}
  end

  # Ignore other PubSub messages
  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if pid = socket.assigns[:pty_pid] do
      try do
        Sam.Session.PTY.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end
  end
end
```

- [ ] **Step 2: Add channel route to UserSocket**

In `lib/sam_web/channels/user_socket.ex`, add after the existing terminal channel:

```elixir
channel "aux_terminal:*", SamWeb.AuxTerminalChannel
```

- [ ] **Step 3: Verify compilation**

Run: `mix compile`
Expected: No errors

- [ ] **Step 4: Commit**

```bash
git add lib/sam_web/channels/aux_terminal_channel.ex lib/sam_web/channels/user_socket.ex
git commit -m "feat: add AuxTerminalChannel for modal shell terminal"
```

---

### Task 2: AuxTerminal JS Hook

**Files:**
- Create: `assets/js/aux_terminal.js`
- Modify: `assets/js/app.js`

- [ ] **Step 1: Create the JS hook**

```javascript
// assets/js/aux_terminal.js
import '@xterm/xterm/css/xterm.css'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { WebglAddon } from '@xterm/addon-webgl'
import { Socket } from 'phoenix'

const AuxTerminalHook = {
  mounted() {
    const sessionId = this.el.dataset.sessionId
    const workdir = this.el.dataset.workdir

    this.term = new Terminal({
      theme: {
        background: '#020f1e',
        foreground: '#d6e4f9',
        cursor: '#22c55e',
        cursorAccent: '#020f1e',
        selectionBackground: 'rgba(175, 201, 234, 0.3)',
        black: '#061423',
        red: '#ffb4ab',
        green: '#22c55e',
        yellow: '#afc9ea',
        blue: '#afc9ea',
        magenta: '#bbc6e2',
        cyan: '#afc9ea',
        white: '#d6e4f9',
      },
      fontFamily: "'Courier New', 'Menlo', monospace",
      fontSize: 13,
      cursorBlink: true,
    })

    this.fitAddon = new FitAddon()
    this.term.loadAddon(this.fitAddon)
    this.term.open(this.el)

    try {
      this.term.loadAddon(new WebglAddon())
    } catch (e) {
      console.warn('WebGL addon not available, using canvas renderer')
    }

    this.fitAddon.fit()

    // Connect to Phoenix channel
    const socket = new Socket('/socket', { params: {} })
    socket.connect()

    this.channel = socket.channel(`aux_terminal:${sessionId}`, { workdir })
    this.channel.join()
      .receive('ok', () => {
        const dims = this.fitAddon.proposeDimensions()
        if (dims) {
          this.channel.push('resize', { cols: dims.cols, rows: dims.rows })
        }
      })
      .receive('error', (resp) => console.error('Failed to join aux terminal', resp))

    // Terminal input → channel
    this.term.onData((data) => {
      this.channel.push('input', { data })
    })

    // Channel output → terminal (base64 → Uint8Array)
    this.channel.on('output', ({ data }) => {
      const binary = atob(data)
      const bytes = new Uint8Array(binary.length)
      for (let i = 0; i < binary.length; i++) {
        bytes[i] = binary.charCodeAt(i)
      }
      this.term.write(bytes)
    })

    // Handle resize
    this.term.onResize(({ cols, rows }) => {
      this.channel.push('resize', { cols, rows })
    })

    // Fit on window resize
    this._resizeHandler = () => this.fitAddon.fit()
    window.addEventListener('resize', this._resizeHandler)
  },

  destroyed() {
    if (this.channel) this.channel.leave()
    if (this.term) this.term.dispose()
    if (this._resizeHandler) window.removeEventListener('resize', this._resizeHandler)
  }
}

export default AuxTerminalHook
```

- [ ] **Step 2: Register hook in app.js**

In `assets/js/app.js`, add import and register:

```javascript
import AuxTerminalHook from "./aux_terminal"
// ... in hooks:
hooks: {...colocatedHooks, Terminal: TerminalHook, Notifications: NotificationsHook, AuxTerminal: AuxTerminalHook},
```

- [ ] **Step 3: Verify assets compile**

Run: `mix assets.build 2>&1 | tail -5`
Expected: No errors

- [ ] **Step 4: Commit**

```bash
git add assets/js/aux_terminal.js assets/js/app.js
git commit -m "feat: add AuxTerminal JS hook for modal shell terminal"
```

---

### Task 3: Terminal Modal LiveComponent + Dashboard Integration

**Files:**
- Create: `lib/sam_web/components/terminal_modal.ex`
- Modify: `lib/sam_web/live/dashboard_live.ex`

- [ ] **Step 1: Create TerminalModal component**

```elixir
# lib/sam_web/components/terminal_modal.ex
defmodule SamWeb.Components.TerminalModal do
  use Phoenix.LiveComponent

  @impl true
  def render(assigns) do
    ~H"""
    <div class={"terminal-modal-overlay #{unless @visible, do: "hidden"}"}>
      <div class="terminal-modal">
        <div class="terminal-modal-header">
          <span class="terminal-modal-title">
            <span class="live-dot"></span> TERMINAL: {@session_name}
          </span>
          <button class="terminal-modal-close" phx-click="toggle_terminal_modal">✕</button>
        </div>
        <div
          class="terminal-modal-body"
          id={"aux-terminal-#{@session_id}"}
          phx-hook="AuxTerminal"
          phx-update="ignore"
          data-session-id={@session_id}
          data-workdir={@workdir}
        >
        </div>
      </div>
    </div>
    """
  end
end
```

- [ ] **Step 2: Add terminal modal to dashboard**

In `lib/sam_web/live/dashboard_live.ex`:

a) Add `show_terminal_modal: false` to mount assigns.

b) Add event handlers:

```elixir
def handle_event("toggle_terminal_modal", _params, socket) do
  {:noreply, assign(socket, show_terminal_modal: !socket.assigns.show_terminal_modal)}
end

def handle_event("close_terminal_modal", _params, socket) do
  {:noreply, assign(socket, show_terminal_modal: false)}
end
```

c) Change the "SHOW TTY" / "HIDE TTY" button to toggle the modal instead:

Replace:
```heex
<button class="sam-btn-outline" phx-click="toggle_terminal">
  {if @show_terminal, do: "HIDE TTY", else: "SHOW TTY"}
</button>
```

With:
```heex
<button class="sam-btn-outline" phx-click="toggle_terminal_modal">
  {if @show_terminal_modal, do: "HIDE TTY", else: "SHOW TTY"}
</button>
```

d) Add the modal component at the end of the template (after settings modal, before closing `</div>`):

```heex
<%= if @selected_session do %>
  <% state = selected_state(@sessions, @selected_session) %>
  <%= if state && !state[:ghost] do %>
    <.live_component
      module={SamWeb.Components.TerminalModal}
      id={"terminal-modal-#{@selected_session}"}
      visible={@show_terminal_modal}
      session_id={@selected_session}
      session_name={state.name || @selected_session}
      workdir={Map.get(state, :workdir) || "."}
    />
  <% end %>
<% end %>
```

- [ ] **Step 3: Run tests**

Run: `mix test`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add lib/sam_web/components/terminal_modal.ex lib/sam_web/live/dashboard_live.ex
git commit -m "feat: add full-screen terminal modal with shell access per session"
```

---

### Task 4: Terminal Modal CSS

**Files:**
- Modify: `assets/css/app.css`

- [ ] **Step 1: Add terminal modal styles**

Append to `assets/css/app.css`:

```css
/* Terminal Modal */
.terminal-modal-overlay.hidden { display: none; }
.terminal-modal-overlay {
  position: fixed;
  inset: 0;
  z-index: 1000;
  background: rgba(0, 0, 0, 0.9);
  display: flex;
  align-items: center;
  justify-content: center;
}

.terminal-modal {
  width: 95vw;
  height: 90vh;
  display: flex;
  flex-direction: column;
  border: 1px solid var(--phosphor-green);
  border-radius: 8px;
  overflow: hidden;
  box-shadow: 0 0 20px rgba(34, 197, 94, 0.15), 0 0 40px rgba(34, 197, 94, 0.05);
}

.terminal-modal-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.5rem 1rem;
  background: var(--surface-dim);
  border-bottom: 1px solid var(--surface-bright);
  font-family: var(--font-mono);
  font-size: 0.75rem;
  color: var(--phosphor-green);
}

.terminal-modal-title {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.terminal-modal-close {
  background: none;
  border: none;
  color: var(--outline);
  cursor: pointer;
  font-size: 1rem;
  padding: 0.25rem 0.5rem;
}

.terminal-modal-close:hover {
  color: var(--status-error);
}

.terminal-modal-body {
  flex: 1;
  background: #020f1e;
}
```

- [ ] **Step 2: Run precommit**

Run: `mix precommit`
Expected: All checks pass

- [ ] **Step 3: Commit**

```bash
git add assets/css/app.css
git commit -m "style: add terminal modal CSS with CRT glow effect"
```

---

### Task 5: Persistence — Save and Load Ghost Sessions

**Files:**
- Modify: `lib/sam/persistence.ex`
- Create: `test/sam/persistence_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# test/sam/persistence_test.exs
defmodule Sam.PersistenceTest do
  use ExUnit.Case, async: false

  setup do
    tmp_dir = System.tmp_dir!()
    dets_path = Path.join(tmp_dir, "test_persistence_#{System.unique_integer([:positive])}")
    {:ok, table} = :dets.open_file(:test_persistence, file: to_charlist(dets_path), type: :set)
    :dets.delete_all_objects(table)

    on_exit(fn ->
      :dets.close(table)
      File.rm(dets_path)
    end)

    %{table: table}
  end

  test "load_saved_sessions returns all entries", %{table: table} do
    :dets.insert(table, {"session-1", %{session_id: "session-1", name: "Test 1", workdir: "/tmp", agent_type: :claude_code, status: :idle}})
    :dets.insert(table, {"session-2", %{session_id: "session-2", name: "Test 2", workdir: "/home", agent_type: :claude_code, status: :working}})

    sessions = Sam.Persistence.load_saved_sessions(table)
    assert length(sessions) == 2
    assert Enum.any?(sessions, &(&1.name == "Test 1"))
  end

  test "delete_session removes entry", %{table: table} do
    :dets.insert(table, {"session-1", %{session_id: "session-1", name: "Del Test"}})
    Sam.Persistence.delete_session(table, "session-1")

    assert :dets.lookup(table, "session-1") == []
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/sam/persistence_test.exs`
Expected: Compilation error — functions not found

- [ ] **Step 3: Add functions to Persistence**

In `lib/sam/persistence.ex`, add public API:

```elixir
def load_saved_sessions(table \\ :sam_persistence) do
  :dets.foldl(
    fn {_id, data}, acc -> [data | acc] end,
    [],
    table
  )
rescue
  ArgumentError -> []
end

def delete_session(table \\ :sam_persistence, session_id) do
  :dets.delete(table, session_id)
rescue
  ArgumentError -> :ok
end
```

Also update `flush_sessions` to include `workdir` and `agent_type`:

```elixir
serializable = %{
  session_id: state.session_id,
  name: state.name,
  status: state.status,
  agent_type: state.agent_type,
  workdir: state.workdir,
  activity: Enum.take(state.activity, 50)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/sam/persistence_test.exs`
Expected: All 2 tests pass

- [ ] **Step 5: Commit**

```bash
git add lib/sam/persistence.ex test/sam/persistence_test.exs
git commit -m "feat: add load_saved_sessions and delete_session to Persistence"
```

---

### Task 6: Ghost Tabs in Dashboard

**Files:**
- Modify: `lib/sam_web/live/dashboard_live.ex`

- [ ] **Step 1: Update mount to load ghost sessions**

In `mount/3`, after `sessions = load_sessions()`, add:

```elixir
saved = Sam.Persistence.load_saved_sessions()
running_ids = Map.keys(sessions)

ghost_sessions =
  saved
  |> Enum.reject(fn s -> s.session_id in running_ids end)
  |> Enum.reduce(%{}, fn s, acc ->
    ghost = %{
      session_id: s.session_id,
      name: s.name || s.session_id,
      status: :disconnected,
      agent_type: Map.get(s, :agent_type, :claude_code),
      workdir: Map.get(s, :workdir),
      branch: nil,
      activity: [],
      agents: [],
      started_at: nil,
      ghost: true
    }
    Map.put(acc, s.session_id, ghost)
  end)

sessions = Map.merge(ghost_sessions, sessions)
```

- [ ] **Step 2: Add restart and dismiss handlers**

```elixir
def handle_event("restart_session", %{"id" => session_id}, socket) do
  ghost = Map.get(socket.assigns.sessions, session_id)

  if ghost && ghost[:ghost] do
    workdir = ghost.workdir || File.cwd!()
    agent_type = ghost.agent_type || :claude_code

    command = agent_command(agent_type, workdir, nil)
    new_session_id = "session-#{System.unique_integer([:positive])}"

    Sam.Session.GroupSupervisor.start_session(%{
      session_id: new_session_id,
      name: ghost.name,
      agent_type: agent_type,
      workdir: workdir,
      command: command
    })

    # Remove old ghost from DETS
    Sam.Persistence.delete_session(session_id)

    sessions =
      socket.assigns.sessions
      |> Map.delete(session_id)
      |> Map.merge(load_sessions())

    {:noreply, assign(socket, sessions: sessions, selected_session: new_session_id)}
  else
    {:noreply, socket}
  end
end

def handle_event("dismiss_ghost", %{"id" => session_id}, socket) do
  Sam.Persistence.delete_session(session_id)
  sessions = Map.delete(socket.assigns.sessions, session_id)
  {:noreply, assign(socket, sessions: sessions)}
end
```

- [ ] **Step 3: Update tab bar to render ghost tabs**

In the tab bar section, update the tab div to handle ghost state:

```heex
<div
  :for={{id, state} <- @sessions}
  class={"sam-tab #{if id == @selected_session, do: "active"} #{if state[:ghost], do: "ghost"}"}
  phx-click={if state[:ghost], do: "restart_session", else: "select_session"}
  phx-value-id={id}
>
  <span class={"status-dot #{status_class(state.status)}"}></span>
  {state.name || id}
  <%= if state[:ghost] do %>
    <span class="ghost-label">RESTART</span>
    <button class="ghost-dismiss" phx-click="dismiss_ghost" phx-value-id={id}>✕</button>
  <% end %>
</div>
```

- [ ] **Step 4: Update kill_session to delete from DETS**

In the existing `handle_event("kill_session", ...)`, add after `GroupSupervisor.terminate_session`:

```elixir
Sam.Persistence.delete_session(session_id)
```

Also in `handle_event("kill_all", ...)`, add DETS cleanup:

```elixir
for session_id <- Sam.Session.Server.list_sessions() do
  Sam.Persistence.delete_session(session_id)
  Sam.Session.GroupSupervisor.terminate_session(session_id)
end
```

- [ ] **Step 5: Update status_class for disconnected**

Add to the `status_class` helper:

```elixir
defp status_class(:disconnected), do: "disconnected"
```

- [ ] **Step 6: Run full test suite**

Run: `mix test`
Expected: All tests pass

- [ ] **Step 7: Commit**

```bash
git add lib/sam_web/live/dashboard_live.ex
git commit -m "feat: ghost tabs for session recovery on SAM restart"
```

---

### Task 7: Ghost Tab CSS

**Files:**
- Modify: `assets/css/app.css`

- [ ] **Step 1: Add ghost tab and disconnected status styles**

Append to `assets/css/app.css`:

```css
/* Ghost tabs */
.sam-tab.ghost {
  opacity: 0.5;
  border-style: dashed;
}
.sam-tab.ghost:hover {
  opacity: 0.8;
}
.ghost-label {
  font-size: 0.6rem;
  color: var(--phosphor-green);
  margin-left: 0.5rem;
  text-transform: uppercase;
  letter-spacing: 0.05em;
}
.ghost-dismiss {
  background: none;
  border: none;
  color: var(--outline);
  cursor: pointer;
  font-size: 0.7rem;
  margin-left: 0.25rem;
  padding: 0 0.2rem;
}
.ghost-dismiss:hover {
  color: var(--status-error);
}

/* Disconnected status dot */
.status-dot.disconnected {
  background: var(--outline);
  opacity: 0.4;
  box-shadow: none;
}
```

- [ ] **Step 2: Run precommit**

Run: `mix precommit`
Expected: All checks pass

- [ ] **Step 3: Commit**

```bash
git add assets/css/app.css
git commit -m "style: add ghost tab and disconnected status CSS"
```

---

### Task 8: End-to-End Verification

**Files:** None (verification only)

- [ ] **Step 1: Run precommit**

Run: `mix precommit`
Expected: All checks pass

- [ ] **Step 2: Restart Phoenix server**

Run: `mix phx.server`

- [ ] **Step 3: Verify modal terminal**

1. Create a session
2. Click "SHOW TTY" button
3. Full-screen terminal modal should appear
4. Run a command (e.g., `ls`, `pwd`) — verify shell is in session's workdir
5. Close modal via X button
6. Reopen — terminal session should still be alive (same shell)

- [ ] **Step 4: Verify ghost tabs**

1. Create 2 sessions with names
2. Stop the Phoenix server (Ctrl+C)
3. Restart with `mix phx.server`
4. Dashboard should show ghost tabs for the 2 previous sessions
5. Click a ghost tab → session restarts with same name/workdir
6. Dismiss the other ghost tab → removed from tab bar

- [ ] **Step 5: Screenshot**

Take screenshots of modal terminal and ghost tabs.
