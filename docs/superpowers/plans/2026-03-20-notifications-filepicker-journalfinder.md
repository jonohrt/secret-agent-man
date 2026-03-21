# Notifications + Directory Picker + Journal Finder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add browser notifications for session status changes, a directory picker with MRU for session creation, and deterministic JSONL file discovery via filesystem watcher.

**Architecture:** Three independent features sharing the existing PubSub-driven architecture. Notifications adds a JS hook on DashboardLive. Directory picker adds a LiveComponent + Settings GenServer. JournalFinder adds a new GenServer to the per-session supervision tree that replaces TranscriptWatcher's flaky birthtime/mtime discovery.

**Tech Stack:** Elixir/Phoenix LiveView, Web Audio API, Browser Notification API, `file_system` hex package, DETS

---

## File Map

### New Files
| File | Responsibility |
|------|---------------|
| `assets/js/notifications.js` | JS hook: browser notifications, Web Audio chime, toast DOM |
| `lib/sam/settings.ex` | GenServer wrapping DETS for user settings (default_workdir, mru_workdirs) |
| `lib/sam_web/components/directory_picker.ex` | LiveComponent for browsable directory tree + MRU chips |
| `lib/sam/session/journal_finder.ex` | GenServer: watches for new JSONL files via FileSystem |
| `test/sam/settings_test.exs` | Settings DETS round-trip tests |
| `test/sam_web/components/directory_picker_test.exs` | DirectoryPicker component tests |
| `test/sam/session/journal_finder_test.exs` | JournalFinder unit tests |

### Modified Files
| File | Changes |
|------|---------|
| `assets/js/app.js` | Import and register Notifications hook |
| `lib/sam_web/live/dashboard_live.ex` | Push notify events on status transitions, integrate DirectoryPicker + Settings modal, sound toggle button |
| `lib/sam/session/group_supervisor.ex` | Add JournalFinder to supervision tree (before PTY, `:temporary` restart) |
| `lib/sam/session/transcript_watcher.ex` | Remove discovery logic, start in `:waiting` state, handle `{:journal_found, path}` |
| `lib/sam/application.ex` | Add `Sam.Settings` to supervision tree |
| `mix.exs` | Add `{:file_system, "~> 1.0"}` dependency |
| `test/sam/session/transcript_watcher_test.exs` | Update tests for new waiting/journal_found flow |

---

### Task 1: Settings GenServer (DETS persistence)

**Files:**
- Create: `lib/sam/settings.ex`
- Create: `test/sam/settings_test.exs`
- Modify: `lib/sam/application.ex:10-21`

- [ ] **Step 1: Write failing tests for Settings**

```elixir
# test/sam/settings_test.exs
defmodule Sam.SettingsTest do
  use ExUnit.Case, async: false

  setup do
    # Use a temp DETS file to avoid polluting real settings
    tmp_dir = System.tmp_dir!()
    dets_path = Path.join(tmp_dir, "test_settings_#{System.unique_integer([:positive])}")
    {:ok, table} = :dets.open_file(:test_settings, file: to_charlist(dets_path), type: :set)
    :dets.delete_all_objects(table)

    on_exit(fn ->
      :dets.close(table)
      File.rm(dets_path)
    end)

    %{table: table}
  end

  test "get returns default when key not set", %{table: table} do
    assert Sam.Settings.get(table, :default_workdir, "/fallback") == "/fallback"
  end

  test "put and get round-trip", %{table: table} do
    Sam.Settings.put(table, :default_workdir, "/Users/johrt/Code/umbrella")
    assert Sam.Settings.get(table, :default_workdir) == "/Users/johrt/Code/umbrella"
  end

  test "mru_workdirs capped at 5 and deduped", %{table: table} do
    for i <- 1..7 do
      Sam.Settings.add_mru_workdir(table, "/path/#{i}")
    end

    dirs = Sam.Settings.get(table, :mru_workdirs, [])
    assert length(dirs) == 5
    # Most recent first
    assert hd(dirs) == "/path/7"
  end

  test "add_mru_workdir deduplicates existing path", %{table: table} do
    Sam.Settings.add_mru_workdir(table, "/path/a")
    Sam.Settings.add_mru_workdir(table, "/path/b")
    Sam.Settings.add_mru_workdir(table, "/path/a")

    dirs = Sam.Settings.get(table, :mru_workdirs, [])
    assert dirs == ["/path/a", "/path/b"]
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/sam/settings_test.exs`
Expected: Compilation error — `Sam.Settings` module not found

- [ ] **Step 3: Implement Settings module**

```elixir
# lib/sam/settings.ex
defmodule Sam.Settings do
  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  # Public API — these work with the GenServer for the global instance,
  # or accept a raw DETS table reference for testing.

  def get(key, default \\ nil), do: get(__MODULE__, key, default)

  def get(table, key, default) when is_atom(table) do
    case :dets.lookup(table_ref(table), key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  def put(key, value), do: put(__MODULE__, key, value)

  def put(table, key, value) when is_atom(table) do
    :dets.insert(table_ref(table), {key, value})
    :ok
  end

  def add_mru_workdir(path), do: add_mru_workdir(__MODULE__, path)

  def add_mru_workdir(table, path) when is_atom(table) do
    current = get(table, :mru_workdirs, [])

    updated =
      [path | Enum.reject(current, &(&1 == path))]
      |> Enum.take(5)

    put(table, :mru_workdirs, updated)
  end

  # GenServer — manages DETS lifecycle

  @impl true
  def init(_) do
    dets_path = Path.join(data_dir(), "sam_settings") |> to_charlist()
    {:ok, table} = :dets.open_file(:sam_settings, file: dets_path, type: :set)
    {:ok, %{table: table}}
  end

  @impl true
  def terminate(_reason, %{table: table}) do
    :dets.close(table)
  end

  # For the GenServer instance, table_ref maps __MODULE__ to the actual DETS table
  # For testing, the raw atom is the DETS table ref directly
  defp table_ref(__MODULE__), do: :sam_settings
  defp table_ref(table), do: table

  defp data_dir do
    dir = Path.join(System.user_home!(), ".config/secret-agent-man/data")
    File.mkdir_p!(dir)
    dir
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/sam/settings_test.exs`
Expected: All 4 tests pass

- [ ] **Step 5: Add Settings to application supervision tree**

In `lib/sam/application.ex`, add `Sam.Settings` after `Sam.Persistence`:

```elixir
Sam.Persistence,
Sam.Settings,
```

- [ ] **Step 6: Run full test suite**

Run: `mix test`
Expected: All tests pass

- [ ] **Step 7: Commit**

```bash
git add lib/sam/settings.ex test/sam/settings_test.exs lib/sam/application.ex
git commit -m "feat: add Sam.Settings GenServer with DETS persistence"
```

---

### Task 2: Notifications JS Hook

**Files:**
- Create: `assets/js/notifications.js`
- Modify: `assets/js/app.js:29-36`

- [ ] **Step 1: Create the Notifications JS hook**

```javascript
// assets/js/notifications.js
const NotificationsHook = {
  mounted() {
    this.permissionGranted = false
    this.soundEnabled = localStorage.getItem("sam-sound-muted") !== "true"
    this.audioCtx = null

    // Request notification permission
    if ("Notification" in window && Notification.permission === "default") {
      Notification.requestPermission().then(perm => {
        this.permissionGranted = perm === "granted"
      })
    } else if ("Notification" in window) {
      this.permissionGranted = Notification.permission === "granted"
    }

    // Handle notify push events from LiveView
    this.handleEvent("notify", ({ status, session_name, session_id }) => {
      const messages = {
        needs_input: "Waiting for input",
        done: "Session completed",
        error: "Session error"
      }
      const message = messages[status] || status

      // Toast (always shown)
      this.showToast(status, session_name, message)

      // Browser notification (only when tab not focused)
      if (!document.hasFocus() && this.permissionGranted) {
        new Notification(`SAM: ${session_name}`, { body: message, tag: session_id })
      }

      // Sound (needs_input and error only)
      if (this.soundEnabled && (status === "needs_input" || status === "error")) {
        this.playChime()
      }
    })
  },

  showToast(status, name, message) {
    let container = document.getElementById("sam-toast-container")
    if (!container) {
      container = document.createElement("div")
      container.id = "sam-toast-container"
      container.style.cssText = "position:fixed;top:1rem;right:1rem;z-index:9999;display:flex;flex-direction:column;gap:0.5rem;pointer-events:none;"
      document.body.appendChild(container)
    }

    const colors = {
      needs_input: "var(--status-input)",
      done: "var(--status-done)",
      error: "var(--status-error)"
    }
    const color = colors[status] || "var(--outline)"

    const toast = document.createElement("div")
    toast.style.cssText = `background:var(--surface-dim);border:1px solid ${color};border-radius:8px;padding:0.75rem 1rem;display:flex;align-items:center;gap:0.75rem;box-shadow:0 4px 12px rgba(0,0,0,0.4);pointer-events:auto;min-width:200px;`
    toast.innerHTML = `
      <div style="width:10px;height:10px;border-radius:50%;background:${color};box-shadow:0 0 6px ${color};flex-shrink:0;"></div>
      <div style="flex:1;">
        <div style="color:var(--on-surface);font-size:0.85rem;font-weight:500;">${this.escapeHtml(name)}</div>
        <div style="color:${color};font-size:0.75rem;">${this.escapeHtml(message)}</div>
      </div>
      <div style="color:var(--outline);cursor:pointer;font-size:0.75rem;padding:0.25rem;" onclick="this.parentElement.remove()">&#10005;</div>
    `
    container.appendChild(toast)
    setTimeout(() => toast.remove(), 5000)
  },

  playChime() {
    try {
      const ctx = this.audioCtx || new (window.AudioContext || window.webkitAudioContext)()
      this.audioCtx = ctx
      const osc = ctx.createOscillator()
      const gain = ctx.createGain()
      osc.connect(gain)
      gain.connect(ctx.destination)
      osc.type = "sine"
      osc.frequency.setValueAtTime(880, ctx.currentTime)
      osc.frequency.setValueAtTime(1100, ctx.currentTime + 0.1)
      gain.gain.setValueAtTime(0.1, ctx.currentTime)
      gain.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.2)
      osc.start(ctx.currentTime)
      osc.stop(ctx.currentTime + 0.2)
    } catch (_) {
      // Autoplay policy may block — silently fail
    }
  },

  escapeHtml(str) {
    const div = document.createElement("div")
    div.textContent = str
    return div.innerHTML
  }
}

export default NotificationsHook
```

- [ ] **Step 2: Register hook in app.js**

In `assets/js/app.js`, add import and register the hook:

```javascript
import NotificationsHook from "./notifications"
// ... in hooks:
hooks: {...colocatedHooks, Terminal: TerminalHook, Notifications: NotificationsHook},
```

- [ ] **Step 3: Verify assets compile**

Run: `cd assets && node_modules/.bin/esbuild js/app.js --bundle --outdir=../priv/static/assets 2>&1 | head -5; cd ..`
Expected: No errors

- [ ] **Step 4: Commit**

```bash
git add assets/js/notifications.js assets/js/app.js
git commit -m "feat: add Notifications JS hook with browser notifications, chime, and toasts"
```

---

### Task 3: Notification Push Events in DashboardLive

**Files:**
- Modify: `lib/sam_web/live/dashboard_live.ex:118-135`
- Modify: `lib/sam_web/live/dashboard_live.ex:244-246` (add hook to root element)
- Create: `test/sam_web/live/notification_push_test.exs`

- [ ] **Step 1: Write failing test for notification push events**

```elixir
# test/sam_web/live/notification_push_test.exs
defmodule SamWeb.NotificationPushTest do
  use SamWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "pushes notify event on transition to needs_input", %{conn: conn} do
    session_id = "test-notif-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      GenServer.start_link(Sam.Session.Server, %{
        session_id: session_id,
        name: "Notif Test"
      })

    on_exit(fn -> GenServer.stop(pid) end)

    {:ok, view, _html} = live(conn, "/")

    # Transition to needs_input
    send(pid, {:parser_event, session_id, %{type: :needs_input, timestamp: DateTime.utc_now()}})

    # The push_event should be sent to the client
    assert_push_event(view, "notify", %{
      status: "needs_input",
      session_name: "Notif Test"
    })
  end

  test "does not push notify event on working transition", %{conn: conn} do
    session_id = "test-notif-no-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      GenServer.start_link(Sam.Session.Server, %{
        session_id: session_id,
        name: "No Notif Test"
      })

    on_exit(fn -> GenServer.stop(pid) end)

    {:ok, view, _html} = live(conn, "/")

    # Transition to working
    send(
      pid,
      {:parser_event, session_id, %{type: :tool_call, tool: "Read", timestamp: DateTime.utc_now()}}
    )

    # Should NOT push a notify event for working
    refute_push_event(view, "notify", %{status: "working"}, 500)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/sam_web/live/notification_push_test.exs`
Expected: FAIL — no push_event being sent

- [ ] **Step 3: Modify DashboardLive to push notify events**

In `lib/sam_web/live/dashboard_live.ex`, update `handle_info` for `:session_update`:

```elixir
@notify_statuses ~w(needs_input done error)a

@impl true
def handle_info({:session_update, session_id, new_state}, socket) do
  session_map = %{
    session_id: new_state.session_id,
    name: new_state.name,
    status: new_state.status,
    agent_type: new_state.agent_type,
    branch: new_state.branch,
    workdir: new_state.workdir,
    activity: new_state.activity,
    agents: new_state.agents
  }

  # Check for notification-worthy transition
  old_status = get_in(socket.assigns.sessions, [session_id, :status])
  new_status = new_state.status

  socket =
    if new_status != old_status and new_status in @notify_statuses do
      push_event(socket, "notify", %{
        status: to_string(new_status),
        session_name: new_state.name || session_id,
        session_id: session_id
      })
    else
      socket
    end

  sessions = Map.put(socket.assigns.sessions, session_id, session_map)
  tick = Map.get(socket.assigns, :tick, 0) + 1
  {:noreply, assign(socket, sessions: sessions, tick: tick)}
end
```

Add `phx-hook="Notifications"` to the root element in `render/1`:

```heex
<div class="sam-shell" id="sam-dashboard" phx-hook="Notifications">
```

- [ ] **Step 4: Add sound mute toggle button to top nav**

In the `sam-topnav-actions` div, before the SETTINGS button:

```heex
<button class="sam-topnav-btn" onclick="window.samToggleSound && window.samToggleSound(this)">
  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
    <polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5" />
    <path d="M15.54 8.46a5 5 0 0 1 0 7.07" />
  </svg>
  SOUND
</button>
```

Add the toggle function to notifications.js mounted() — capture `this` in a closure variable:

```javascript
const self = this
window.samToggleSound = (btn) => {
  self.soundEnabled = !self.soundEnabled
  localStorage.setItem("sam-sound-muted", !self.soundEnabled)
  btn.style.opacity = self.soundEnabled ? "1" : "0.4"
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/sam_web/live/notification_push_test.exs`
Expected: All tests pass

- [ ] **Step 6: Run full test suite**

Run: `mix test`
Expected: All tests pass

- [ ] **Step 7: Commit**

```bash
git add lib/sam_web/live/dashboard_live.ex test/sam_web/live/notification_push_test.exs
git commit -m "feat: push notification events on status transitions (needs_input, done, error)"
```

---

### Task 4: Directory Picker LiveComponent

**Files:**
- Create: `lib/sam_web/components/directory_picker.ex`
- Create: `test/sam_web/components/directory_picker_test.exs`

- [ ] **Step 1: Write failing tests for DirectoryPicker**

```elixir
# test/sam_web/components/directory_picker_test.exs
defmodule SamWeb.Components.DirectoryPickerTest do
  use SamWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias SamWeb.Components.DirectoryPicker

  @tag :tmp_dir
  test "renders base path and MRU chips", %{tmp_dir: tmp_dir} do
    # Create some subdirectories
    File.mkdir_p!(Path.join(tmp_dir, "apps/api"))
    File.mkdir_p!(Path.join(tmp_dir, "apps/web"))

    assigns = %{
      base_path: tmp_dir,
      mru_paths: [Path.join(tmp_dir, "apps/api"), Path.join(tmp_dir, "apps/web")],
      selected_path: tmp_dir
    }

    html = render_component(DirectoryPicker, assigns)

    assert html =~ "apps/api"
    assert html =~ "apps/web"
  end

  @tag :tmp_dir
  test "lists only directories, not files", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "src"))
    File.write!(Path.join(tmp_dir, "mix.exs"), "")

    assigns = %{base_path: tmp_dir, mru_paths: [], selected_path: tmp_dir, browsing: true, current_dir: tmp_dir}

    html = render_component(DirectoryPicker, assigns)

    assert html =~ "src"
    refute html =~ "mix.exs"
  end

  @tag :tmp_dir
  test "hides dotfiles", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, ".git"))
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    assigns = %{base_path: tmp_dir, mru_paths: [], selected_path: tmp_dir, browsing: true, current_dir: tmp_dir}

    html = render_component(DirectoryPicker, assigns)

    assert html =~ "lib"
    refute html =~ ".git"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/sam_web/components/directory_picker_test.exs`
Expected: Compilation error — module not found

- [ ] **Step 3: Implement DirectoryPicker component**

```elixir
# lib/sam_web/components/directory_picker.ex
defmodule SamWeb.Components.DirectoryPicker do
  use Phoenix.LiveComponent

  @impl true
  def mount(socket) do
    {:ok, assign(socket, browsing: false, current_dir: nil, error: nil)}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:current_dir, fn -> assigns[:base_path] || "" end)
      |> assign_new(:browsing, fn -> false end)

    {:ok, socket}
  end

  @impl true
  def handle_event("browse_toggle", _params, socket) do
    browsing = !socket.assigns.browsing
    current_dir = if browsing, do: socket.assigns.base_path, else: socket.assigns.current_dir
    {:noreply, assign(socket, browsing: browsing, current_dir: current_dir, error: nil)}
  end

  def handle_event("navigate", %{"path" => path}, socket) do
    expanded = expand_path(path)

    if File.dir?(expanded) do
      {:noreply, assign(socket, current_dir: expanded, error: nil)}
    else
      {:noreply, assign(socket, error: "Not a directory")}
    end
  end

  def handle_event("select_dir", %{"path" => path}, socket) do
    send(self(), {:directory_selected, expand_path(path)})
    {:noreply, assign(socket, browsing: false)}
  end

  def handle_event("select_mru", %{"path" => path}, socket) do
    send(self(), {:directory_selected, path})
    {:noreply, socket}
  end

  def handle_event("navigate_up", _params, socket) do
    parent = Path.dirname(socket.assigns.current_dir)
    {:noreply, assign(socket, current_dir: parent, error: nil)}
  end

  @impl true
  def render(assigns) do
    dirs = if assigns[:browsing], do: list_dirs(assigns.current_dir), else: []
    assigns = assign(assigns, :dirs, dirs)

    ~H"""
    <div class="directory-picker">
      <%!-- MRU chips --%>
      <div :if={@mru_paths != []} class="picker-mru">
        <span
          :for={path <- @mru_paths}
          class="picker-chip"
          phx-click="select_mru"
          phx-value-path={path}
          phx-target={@myself}
        >
          {Path.relative_to(path, @base_path)}
        </span>
        <span class="picker-mru-label">recent</span>
      </div>

      <%!-- Path input + browse button --%>
      <div class="picker-input-row">
        <input
          type="text"
          name="workdir"
          value={@selected_path}
          class="modal-input"
          style="font-family: var(--font-mono); font-size: 10px; flex: 1;"
        />
        <button
          type="button"
          class="picker-browse-btn"
          phx-click="browse_toggle"
          phx-target={@myself}
        >
          {if @browsing, do: "CLOSE", else: "BROWSE"}
        </button>
      </div>

      <%!-- Directory tree --%>
      <div :if={@browsing} class="picker-tree">
        <div class="picker-breadcrumb">{@current_dir}</div>
        <div :if={@error} class="picker-error">{@error}</div>

        <div
          :if={@current_dir != "/"}
          class="picker-dir"
          phx-click="navigate_up"
          phx-target={@myself}
        >
          📂 ..
        </div>

        <div
          :for={dir <- @dirs}
          class="picker-dir"
          phx-click="navigate"
          phx-value-path={Path.join(@current_dir, dir)}
          phx-target={@myself}
        >
          📂 {dir}/
          <button
            type="button"
            class="picker-select-btn"
            phx-click="select_dir"
            phx-value-path={Path.join(@current_dir, dir)}
            phx-target={@myself}
          >
            SELECT
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp list_dirs(nil), do: []

  defp list_dirs(path) do
    expanded = expand_path(path)

    case File.ls(expanded) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.filter(&File.dir?(Path.join(expanded, &1)))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp expand_path(path) do
    if String.starts_with?(path, "~") do
      String.replace_prefix(path, "~", System.user_home!())
    else
      path
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/sam_web/components/directory_picker_test.exs`
Expected: All 3 tests pass

- [ ] **Step 5: Commit**

```bash
git add lib/sam_web/components/directory_picker.ex test/sam_web/components/directory_picker_test.exs
git commit -m "feat: add DirectoryPicker LiveComponent with browse tree and MRU chips"
```

---

### Task 5: Integrate Directory Picker into Dashboard

**Files:**
- Modify: `lib/sam_web/live/dashboard_live.ex:74-116` (create_session handler)
- Modify: `lib/sam_web/live/dashboard_live.ex:500-572` (modal template)
- Modify: `lib/sam_web/live/dashboard_live.ex:5-21` (mount — load settings)

- [ ] **Step 1: Update mount to load settings**

In `dashboard_live.ex` mount, add settings assigns:

```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")
  end

  sessions = load_sessions()
  selected = List.first(Map.keys(sessions))

  default_workdir = Sam.Settings.get(:default_workdir, File.cwd!())
  mru_workdirs = Sam.Settings.get(:mru_workdirs, [])

  {:ok,
   assign(socket,
     sessions: sessions,
     selected_session: selected,
     show_new_dialog: false,
     show_terminal: false,
     show_settings: false,
     input_text: "",
     tick: 0,
     default_workdir: default_workdir,
     mru_workdirs: mru_workdirs
   )}
end
```

- [ ] **Step 2: Update create_session to save MRU**

In `handle_event("create_session", ...)`, after resolving workdir add:

```elixir
Sam.Settings.add_mru_workdir(workdir)
mru_workdirs = Sam.Settings.get(:mru_workdirs, [])
```

And include `mru_workdirs: mru_workdirs` in the final assign.

- [ ] **Step 3: Add directory_selected handler**

```elixir
def handle_info({:directory_selected, path}, socket) do
  {:noreply, assign(socket, selected_workdir: path)}
end
```

- [ ] **Step 4: Replace workdir text input with DirectoryPicker in modal**

Replace the DEPLOYMENT_VECTOR field in the modal form with:

```heex
<div class="modal-field">
  <label class="modal-label">DEPLOYMENT_VECTOR</label>
  <.live_component
    module={SamWeb.Components.DirectoryPicker}
    id="workdir-picker"
    base_path={@default_workdir}
    mru_paths={@mru_workdirs}
    selected_path={assigns[:selected_workdir] || @default_workdir}
  />
</div>
```

- [ ] **Step 5: Add Settings modal (gear button handler + minimal modal)**

Add handler:

```elixir
def handle_event("toggle_settings", _params, socket) do
  {:noreply, assign(socket, show_settings: !socket.assigns.show_settings)}
end

def handle_event("save_settings", %{"default_workdir" => path}, socket) do
  expanded = if String.starts_with?(path, "~"), do: String.replace_prefix(path, "~", System.user_home!()), else: path
  Sam.Settings.put(:default_workdir, expanded)
  {:noreply, assign(socket, default_workdir: expanded, show_settings: false)}
end
```

Wire the existing SETTINGS button: `phx-click="toggle_settings"`

Add settings modal after the create session modal:

```heex
<%= if @show_settings do %>
  <div class="modal-overlay">
    <section class="modal-panel" phx-click-away="toggle_settings">
      <div class="modal-grid-bg"></div>
      <div class="modal-scan"></div>
      <div class="modal-content">
        <h1 class="modal-title">Settings</h1>
        <form phx-submit="save_settings">
          <div class="modal-field">
            <label class="modal-label">DEFAULT_WORKDIR</label>
            <input class="modal-input" type="text" name="default_workdir" value={@default_workdir}
              style="font-family: var(--font-mono); font-size: 10px;" />
          </div>
          <div class="modal-footer">
            <button type="button" class="modal-abort" phx-click="toggle_settings">CANCEL</button>
            <button type="submit" class="modal-submit">SAVE</button>
          </div>
        </form>
      </div>
    </section>
  </div>
<% end %>
```

- [ ] **Step 6: Run full test suite**

Run: `mix test`
Expected: All tests pass

- [ ] **Step 7: Commit**

```bash
git add lib/sam_web/live/dashboard_live.ex
git commit -m "feat: integrate DirectoryPicker and Settings modal into dashboard"
```

---

### Task 6: Add file_system Dependency

**Files:**
- Modify: `mix.exs:45-71`

- [ ] **Step 1: Add file_system to deps**

In `mix.exs` deps list, add:

```elixir
{:file_system, "~> 1.0"},
```

- [ ] **Step 2: Fetch dependency**

Run: `mix deps.get`
Expected: `file_system` downloaded successfully

- [ ] **Step 3: Verify compilation**

Run: `mix compile`
Expected: No errors

- [ ] **Step 4: Commit**

```bash
git add mix.exs mix.lock
git commit -m "chore: add file_system dependency for JSONL file discovery"
```

---

### Task 7: JournalFinder GenServer

**Files:**
- Create: `lib/sam/session/journal_finder.ex`
- Create: `test/sam/session/journal_finder_test.exs`

- [ ] **Step 1: Write failing tests for JournalFinder**

```elixir
# test/sam/session/journal_finder_test.exs
defmodule Sam.Session.JournalFinderTest do
  use ExUnit.Case, async: false

  @tag :tmp_dir
  test "detects new .jsonl file in watched directory", %{tmp_dir: tmp_dir} do
    session_id = "test-jf-#{System.unique_integer([:positive])}"
    watch_dir = Path.join(tmp_dir, "watch")
    File.mkdir_p!(watch_dir)

    test_pid = self()

    {:ok, pid} =
      GenServer.start_link(Sam.Session.JournalFinder, %{
        session_id: session_id,
        watch_dir: watch_dir,
        notify_pid: test_pid
      })

    # Give FileSystem watcher time to start
    Process.sleep(500)

    # Create a .jsonl file
    jsonl_path = Path.join(watch_dir, "test-session.jsonl")
    File.write!(jsonl_path, "")

    assert_receive {:journal_found, ^jsonl_path}, 5000

    GenServer.stop(pid)
  end

  @tag :tmp_dir
  test "ignores non-.jsonl files", %{tmp_dir: tmp_dir} do
    session_id = "test-jf-ignore-#{System.unique_integer([:positive])}"
    watch_dir = Path.join(tmp_dir, "watch")
    File.mkdir_p!(watch_dir)

    test_pid = self()

    {:ok, pid} =
      GenServer.start_link(Sam.Session.JournalFinder, %{
        session_id: session_id,
        watch_dir: watch_dir,
        notify_pid: test_pid
      })

    Process.sleep(500)

    # Create a non-jsonl file
    File.write!(Path.join(watch_dir, "not-a-journal.txt"), "")

    refute_receive {:journal_found, _}, 2000

    GenServer.stop(pid)
  end

  @tag :tmp_dir
  test "timeout triggers warning and stays idle", %{tmp_dir: tmp_dir} do
    session_id = "test-jf-timeout-#{System.unique_integer([:positive])}"
    watch_dir = Path.join(tmp_dir, "watch")
    File.mkdir_p!(watch_dir)

    test_pid = self()

    {:ok, pid} =
      GenServer.start_link(Sam.Session.JournalFinder, %{
        session_id: session_id,
        watch_dir: watch_dir,
        notify_pid: test_pid,
        timeout_ms: 500
      })

    # Wait for timeout
    Process.sleep(1000)

    # Should not have sent journal_found
    refute_receive {:journal_found, _}, 100

    # Process should still be alive
    assert Process.alive?(pid)

    GenServer.stop(pid)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/sam/session/journal_finder_test.exs`
Expected: Compilation error — module not found

- [ ] **Step 3: Implement JournalFinder**

```elixir
# lib/sam/session/journal_finder.ex
defmodule Sam.Session.JournalFinder do
  @moduledoc """
  Watches a directory for new .jsonl files created by Claude Code.
  When found, sends {:journal_found, path} to the TranscriptWatcher.
  Self-terminates the watcher after finding the file.
  """
  use GenServer
  require Logger

  @default_timeout_ms 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    session_id = Map.fetch!(opts, :session_id)
    watch_dir = Map.fetch!(opts, :watch_dir)
    notify_pid = Map.get(opts, :notify_pid)
    timeout_ms = Map.get(opts, :timeout_ms, @default_timeout_ms)

    File.mkdir_p!(watch_dir)

    {:ok, watcher_pid} = FileSystem.start_link(dirs: [watch_dir])
    FileSystem.subscribe(watcher_pid)

    timer_ref = Process.send_after(self(), :timeout, timeout_ms)

    {:ok,
     %{
       session_id: session_id,
       watch_dir: watch_dir,
       watcher_pid: watcher_pid,
       notify_pid: notify_pid,
       timer_ref: timer_ref,
       found: false
     }}
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, events}}, %{found: false} = state) do
    if String.ends_with?(path, ".jsonl") and :created in events do
      Logger.info("[JournalFinder] Found JSONL: #{Path.basename(path)}")

      # Notify TranscriptWatcher (or test pid)
      notify_target(state, path)

      # Stop the filesystem watcher (no longer needed)
      GenServer.stop(state.watcher_pid)
      Process.cancel_timer(state.timer_ref)

      {:noreply, %{state | found: true}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _watcher_pid, {_path, _events}}, state) do
    # Already found — ignore
    {:noreply, state}
  end

  def handle_info(:timeout, %{found: false} = state) do
    Logger.warning(
      "[JournalFinder] Timeout waiting for JSONL file for session #{state.session_id}"
    )

    GenServer.stop(state.watcher_pid)
    {:noreply, %{state | found: false}}
  end

  def handle_info(:timeout, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{found: false} = state) do
    # Cleanup watcher if still running
    try do
      GenServer.stop(state.watcher_pid)
    catch
      :exit, _ -> :ok
    end
  end

  def terminate(_reason, _state), do: :ok

  defp notify_target(%{notify_pid: pid}, path) when is_pid(pid) do
    send(pid, {:journal_found, path})
  end

  defp notify_target(%{session_id: session_id}, path) do
    case Registry.lookup(Sam.ProcessRegistry, {:transcript_watcher, session_id}) do
      [{pid, _}] ->
        send(pid, {:journal_found, path})

      [] ->
        Logger.warning("[JournalFinder] TranscriptWatcher not found for #{session_id}")
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/sam/session/journal_finder_test.exs`
Expected: All 3 tests pass

- [ ] **Step 5: Commit**

```bash
git add lib/sam/session/journal_finder.ex test/sam/session/journal_finder_test.exs
git commit -m "feat: add JournalFinder GenServer for deterministic JSONL file discovery"
```

---

### Task 8: Update TranscriptWatcher for journal_found Flow

**Files:**
- Modify: `lib/sam/session/transcript_watcher.ex`
- Modify: `test/sam/session/transcript_watcher_test.exs`

- [ ] **Step 1: Write failing test for journal_found handler**

Add to `test/sam/session/transcript_watcher_test.exs`:

```elixir
@tag :tmp_dir
test "transitions from waiting to watching on journal_found", %{tmp_dir: tmp_dir} do
  session_id = "test-tw-jf-#{System.unique_integer([:positive])}"
  jsonl_path = Path.join(tmp_dir, "session.jsonl")
  File.write!(jsonl_path, "")

  Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

  # Start watcher WITHOUT a test path (simulates waiting state)
  {:ok, pid} =
    GenServer.start_link(Sam.Session.TranscriptWatcher, %{
      session_id: session_id,
      workdir: nil,
      _test_project_dir: Path.join(tmp_dir, "nonexistent")
    })

  # Verify it's in waiting state (no path found)
  state = :sys.get_state(pid)
  assert state.path == nil

  # Send journal_found
  send(pid, {:journal_found, jsonl_path})

  # Give it time to process
  Process.sleep(200)

  # Now append data and verify events flow
  record =
    Jason.encode!(%{
      "message" => %{
        "role" => "assistant",
        "content" => [
          %{"type" => "tool_use", "id" => "t1", "name" => "Read", "input" => %{}}
        ]
      }
    })

  File.write!(jsonl_path, record <> "\n", [:append])
  assert_receive {:parser_event, ^session_id, %{type: :tool_call, tool: "Read"}}, 3000

  GenServer.stop(pid)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/sam/session/transcript_watcher_test.exs`
Expected: FAIL — no handler for `:journal_found`

- [ ] **Step 3: Update TranscriptWatcher**

Modify `lib/sam/session/transcript_watcher.ex`:

1. Remove `find_session_jsonl/1`, `find_by_birthtime/2`, `find_by_mtime/1`, `get_birthtime/1`
2. Remove `@discovery_timeout_ms`
3. Update the `handle_info(:poll, %{path: nil})` to simply reschedule (no discovery):

```elixir
def handle_info(:poll, %{path: nil} = state) do
  # Waiting for JournalFinder to send {:journal_found, path}
  schedule_poll()
  {:noreply, state}
end
```

4. Add handler for `{:journal_found, path}`:

```elixir
def handle_info({:journal_found, path}, state) do
  Logger.info("[TranscriptWatcher] Received journal path: #{Path.basename(path)}")
  offset = file_size(path)
  {:noreply, %{state | path: path, offset: offset}}
end
```

5. Keep `_test_jsonl_path` support in init for existing tests.

6. Register with the process registry so JournalFinder can find it. Update `start_link`:

```elixir
def start_link(opts) do
  session_id = Map.fetch!(opts, :session_id)
  name = {:via, Registry, {Sam.ProcessRegistry, {:transcript_watcher, session_id}}}
  GenServer.start_link(__MODULE__, opts, name: name)
end
```

- [ ] **Step 4: Update existing discovery tests**

Remove or update the `"picks the most recently modified JSONL file"` test since discovery is now handled by JournalFinder. Keep the JSONL parsing tests as-is (they use `_test_jsonl_path`).

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/sam/session/transcript_watcher_test.exs`
Expected: All tests pass

- [ ] **Step 6: Run full test suite**

Run: `mix test`
Expected: All tests pass

- [ ] **Step 7: Commit**

```bash
git add lib/sam/session/transcript_watcher.ex test/sam/session/transcript_watcher_test.exs
git commit -m "refactor: TranscriptWatcher receives path from JournalFinder instead of self-discovering"
```

---

### Task 9: Wire JournalFinder into Supervision Tree

**Files:**
- Modify: `lib/sam/session/group_supervisor.ex:40-78`

- [ ] **Step 1: Write integration test**

```elixir
# Add to test/sam/session/journal_finder_test.exs
@tag :tmp_dir
test "JournalFinder sends path to TranscriptWatcher via Registry", %{tmp_dir: tmp_dir} do
  session_id = "test-jf-reg-#{System.unique_integer([:positive])}"
  watch_dir = Path.join(tmp_dir, "watch")
  File.mkdir_p!(watch_dir)

  # Start a TranscriptWatcher registered in the process registry
  {:ok, tw_pid} =
    GenServer.start_link(Sam.Session.TranscriptWatcher, %{
      session_id: session_id,
      workdir: nil,
      _test_project_dir: Path.join(tmp_dir, "nonexistent")
    })

  # Start JournalFinder without explicit notify_pid — should use Registry
  {:ok, jf_pid} =
    GenServer.start_link(Sam.Session.JournalFinder, %{
      session_id: session_id,
      watch_dir: watch_dir
    })

  Process.sleep(500)

  # Create JSONL file
  jsonl_path = Path.join(watch_dir, "test.jsonl")
  File.write!(jsonl_path, "")

  # TranscriptWatcher should have received the path
  # Use assert_receive on a monitor to avoid Process.sleep
  # Poll via :sys.get_state with a bounded wait
  assert wait_for(fn -> :sys.get_state(tw_pid).path == jsonl_path end, 5000),
    "TranscriptWatcher did not receive journal path within timeout"

  GenServer.stop(jf_pid)
  GenServer.stop(tw_pid)
end

defp wait_for(fun, timeout, interval \\ 100) do
  deadline = System.monotonic_time(:millisecond) + timeout
  do_wait_for(fun, deadline, interval)
end

defp do_wait_for(fun, deadline, interval) do
  if fun.() do
    true
  else
    if System.monotonic_time(:millisecond) >= deadline do
      false
    else
      Process.sleep(interval)
      do_wait_for(fun, deadline, interval)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it passes (or fails if Registry lookup isn't wired)**

Run: `mix test test/sam/session/journal_finder_test.exs`

- [ ] **Step 3: Add JournalFinder to GroupSupervisor**

In `lib/sam/session/group_supervisor.ex`, update the children list in `init/1`. Add JournalFinder *after* PTY with `:temporary` restart. This ensures a JournalFinder crash never cascades to PTY via `rest_for_one`. The race window is negligible — Claude Code takes several seconds to start before creating a JSONL file, and JournalFinder's FileSystem watcher starts in milliseconds:

```elixir
children = [
  %{
    id: Sam.Session.Server,
    start: {Sam.Session.Server, :start_link, [opts]}
  },
  %{
    id: Sam.Session.Summarizer,
    start: {Sam.Session.Summarizer, :start_link, [%{session_id: session_id}]}
  },
  %{
    id: Sam.Session.Parser,
    start: {Sam.Session.Parser, :start_link, [%{session_id: session_id}]}
  },
  %{
    id: Sam.Session.TranscriptWatcher,
    start:
      {Sam.Session.TranscriptWatcher, :start_link,
       [%{session_id: session_id, workdir: Map.get(opts, :workdir)}]}
  },
  %{
    id: Sam.Session.PTY,
    start:
      {Sam.Session.PTY, :start_link,
       [
         %{
           session_id: session_id,
           command: command,
           workdir: Map.get(opts, :workdir)
         }
       ]}
  },
  %{
    id: Sam.Session.JournalFinder,
    start:
      {Sam.Session.JournalFinder, :start_link,
       [%{session_id: session_id, watch_dir: journal_watch_dir(Map.get(opts, :workdir))}]},
    restart: :temporary
  }
]
```

Add helper:

```elixir
defp journal_watch_dir(nil) do
  cwd = File.cwd!()
  encoded = String.replace(cwd, "/", "-")
  Path.join(Path.join(System.user_home!(), ".claude/projects"), encoded)
end

defp journal_watch_dir(workdir) do
  encoded = String.replace(workdir, "/", "-")
  Path.join(Path.join(System.user_home!(), ".claude/projects"), encoded)
end
```

- [ ] **Step 4: Run full test suite**

Run: `mix test`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add lib/sam/session/group_supervisor.ex test/sam/session/journal_finder_test.exs
git commit -m "feat: wire JournalFinder into session supervision tree (temporary restart)"
```

---

### Task 10: CSS for Directory Picker + Toast

**Files:**
- Modify: `assets/css/themes.css` or the appropriate CSS file

- [ ] **Step 1: Find the main CSS file for component styles**

Check `assets/css/app.css` or similar for where component styles live.

- [ ] **Step 2: Add directory picker styles**

```css
/* Directory Picker */
.picker-mru { display: flex; gap: 0.5rem; margin-bottom: 0.75rem; flex-wrap: wrap; }
.picker-chip {
  background: rgba(175,201,234,0.1); border: 1px solid rgba(175,201,234,0.2);
  border-radius: 999px; padding: 0.3rem 0.75rem; font-size: 0.75rem;
  color: var(--primary); cursor: pointer; font-family: var(--font-mono);
}
.picker-chip:hover { background: rgba(34,197,94,0.15); border-color: rgba(34,197,94,0.3); color: var(--phosphor-green); }
.picker-mru-label { color: var(--outline); font-size: 0.7rem; align-self: center; margin-left: 0.25rem; }
.picker-input-row { display: flex; gap: 0.5rem; margin-bottom: 0.75rem; }
.picker-browse-btn {
  background: var(--phosphor-green); color: var(--surface); border: none; border-radius: 6px;
  padding: 0.6rem 0.8rem; font-weight: 600; font-size: 0.75rem; cursor: pointer; white-space: nowrap;
  font-family: var(--font-body); text-transform: uppercase; letter-spacing: 0.05em;
}
.picker-tree {
  background: var(--surface); border: 1px solid var(--surface-bright);
  border-radius: 6px; padding: 0.75rem; font-family: var(--font-mono);
  font-size: 0.8rem; max-height: 200px; overflow-y: auto;
}
.picker-breadcrumb { color: var(--outline); margin-bottom: 0.5rem; font-size: 0.7rem; }
.picker-error { color: var(--status-error); font-size: 0.75rem; margin-bottom: 0.5rem; }
.picker-dir {
  color: var(--on-surface); padding: 0.2rem 0.5rem; cursor: pointer;
  display: flex; align-items: center; justify-content: space-between; border-radius: 4px;
}
.picker-dir:hover { background: rgba(34,197,94,0.1); }
.picker-select-btn {
  background: none; border: 1px solid var(--phosphor-green); color: var(--phosphor-green);
  border-radius: 4px; padding: 0.1rem 0.4rem; font-size: 0.65rem; cursor: pointer;
  opacity: 0; transition: opacity 0.15s;
}
.picker-dir:hover .picker-select-btn { opacity: 1; }
```

- [ ] **Step 3: Run precommit**

Run: `mix precommit`
Expected: All checks pass

- [ ] **Step 4: Commit**

```bash
git add assets/css/
git commit -m "style: add directory picker and toast CSS"
```

---

### Task 11: End-to-End Verification

**Files:** None (verification only)

- [ ] **Step 1: Run full test suite**

Run: `mix precommit`
Expected: All checks pass (compile, format, test)

- [ ] **Step 2: Start Phoenix server**

Run: `mix phx.server`

- [ ] **Step 3: Verify notifications**

1. Open dashboard in browser
2. Create a session
3. When session transitions to `needs_input`, verify:
   - Toast appears top-right
   - Browser notification appears (if tab not focused)
   - No sound (off by default)
4. Click SOUND button to enable
5. Trigger another `needs_input` — verify chime plays

- [ ] **Step 4: Verify directory picker**

1. Click SETTINGS → set default workdir to umbrella project root
2. Click DEPLOY AGENT → verify MRU chips empty (first use)
3. Click Browse → verify directory tree shows subdirectories
4. Select a directory → verify path fills into input
5. Create session → verify MRU chip appears on next modal open

- [ ] **Step 5: Verify JournalFinder**

1. Create a new session
2. Check Phoenix server logs for `[JournalFinder] Found JSONL: <uuid>.jsonl`
3. Check that status dot transitions work (green when working, gray when idle)

- [ ] **Step 6: Take screenshots**

Use `mcp__screenshot-website-fast__take_screenshot` to capture:
- Toast notification appearing
- Directory picker expanded with MRU chips
- Status dots working with JournalFinder

- [ ] **Step 7: Final commit**

```bash
git add -A
git commit -m "feat: notifications, directory picker, and journal finder — verified E2E"
```
