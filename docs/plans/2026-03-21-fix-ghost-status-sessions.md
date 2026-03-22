# Fix Ghost Terminals, Status Indicator, and Sessions Panel — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix three interconnected bugs: status stuck on idle (hooks not installed), ghost terminals after restart (stale DETS), and sessions panel showing same content as activity feed (shared data source).

**Architecture:** Three independent fixes: (1) auto-register Claude Code hooks on app startup, (2) clean stale DETS entries on Persistence init, (3) add dedicated `summary` field to Server state so session cards and activity feed read from different sources.

**Tech Stack:** Elixir/Phoenix, DETS, GenServer, PubSub, Claude Code hooks (bash script)

---

### Task 1: Clean Stale DETS on Startup (Ghost Terminal Fix)

**Files:**
- Modify: `lib/sam/persistence.ex:12-16` (init/1)
- Test: `test/sam/persistence_test.exs`

**Step 1: Write the failing test**

Add to `test/sam/persistence_test.exs`:

```elixir
test "cleanup_stale removes all entries from table", %{table: table} do
  :dets.insert(table, {"session-1", %{session_id: "session-1", name: "Stale"}})
  :dets.insert(table, {"session-2", %{session_id: "session-2", name: "Also Stale"}})

  Sam.Persistence.cleanup_stale(table)

  assert Sam.Persistence.load_saved_sessions(table) == []
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/sam/persistence_test.exs --seed 0`
Expected: FAIL — `cleanup_stale/1` is undefined

**Step 3: Implement cleanup_stale and call from init**

In `lib/sam/persistence.ex`, add after `delete_session/2` (around line 46):

```elixir
def cleanup_stale(table \\ :sam_persistence) do
  :dets.delete_all_objects(table)
rescue
  ArgumentError -> :ok
end
```

In `init/1`, add after `:dets.open_file` and before `schedule_flush()`:

```elixir
cleanup_stale(table)
```

So init becomes:
```elixir
def init(_) do
  dets_path = Path.join(data_dir(), "sam_sessions") |> to_charlist()
  {:ok, table} = :dets.open_file(:sam_persistence, file: dets_path, type: :set)
  cleanup_stale(table)
  schedule_flush()
  {:ok, %{table: table}}
end
```

**Step 4: Run test to verify it passes**

Run: `mix test test/sam/persistence_test.exs --seed 0`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/sam/persistence.ex test/sam/persistence_test.exs
git commit -m "fix: clean stale DETS entries on startup to prevent ghost terminals"
```

---

### Task 2: Add Dedicated Summary Field to Server State

**Files:**
- Modify: `lib/sam/session/server.ex:7-19` (struct), `lib/sam/session/server.ex:229-241` (summary handler), `lib/sam/session/server.ex:324-331` (sanitize_state)
- Test: `test/sam/session/server_test.exs`

**Step 1: Write the failing test**

Add to `test/sam/session/server_test.exs` in the `"summary events"` describe block:

```elixir
test "summary event updates dedicated summary field" do
  session_id = "test-summary-field-#{System.unique_integer([:positive])}"

  Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")

  {:ok, pid} =
    GenServer.start_link(Sam.Session.Server, %{session_id: session_id, name: "SumField Test"})

  assert_receive {:session_update, ^session_id, %{summary: "Awaiting directives..."}}, 1000

  Phoenix.PubSub.broadcast(
    Sam.PubSub,
    "session:#{session_id}",
    {:summary, session_id,
     %{
       text: "Refactoring auth module",
       source: :ollama,
       tool_count: 3,
       timestamp: DateTime.utc_now()
     }}
  )

  assert_receive {:session_update, ^session_id, state}, 1000
  assert state.summary == "Refactoring auth module"

  # Activity list should ALSO have it (for the chronological feed)
  assert [%{text: "Refactoring auth module"} | _] = state.activity

  GenServer.stop(pid)
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/sam/session/server_test.exs --seed 0`
Expected: FAIL — no `:summary` key in state

**Step 3: Add summary field to struct and update handler**

In `lib/sam/session/server.ex`, update the struct (line 7-19):

```elixir
defstruct [
  :session_id,
  :name,
  :agent_type,
  :branch,
  :workdir,
  :idle_timer,
  :idle_timeout_ms,
  :started_at,
  status: :idle,
  activity: [],
  agents: [],
  summary: "Awaiting directives..."
]
```

Update the summary handler (line 229-241):

```elixir
@impl true
def handle_info({:summary, _session_id, %{text: text} = payload}, state) do
  entry = %{
    type: :summary,
    text: text,
    source: Map.get(payload, :source, :heuristic),
    tool_count: Map.get(payload, :tool_count, 0),
    timestamp: DateTime.utc_now()
  }

  state = %{state | activity: [entry | state.activity] |> Enum.take(50), summary: text}
  broadcast_ui_update(state)
  {:noreply, state}
end
```

Update `sanitize_state/1` to sanitize the summary field too:

```elixir
defp sanitize_state(state) do
  clean_activity =
    Enum.map(state.activity, fn entry ->
      %{entry | text: sanitize_utf8(Map.get(entry, :text, ""))}
    end)

  %{state | idle_timer: nil, activity: clean_activity, summary: sanitize_utf8(state.summary)}
end
```

**Step 4: Run test to verify it passes**

Run: `mix test test/sam/session/server_test.exs --seed 0`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/sam/session/server.ex test/sam/session/server_test.exs
git commit -m "feat: add dedicated summary field to session server state"
```

---

### Task 3: Update Dashboard to Use Summary Field

**Files:**
- Modify: `lib/sam_web/live/dashboard_live.ex`

**Step 1: Update session maps to include summary**

In `load_sessions/0` (line 305-330), add `summary` to the session_map:

```elixir
session_map = %{
  session_id: state.session_id,
  name: state.name,
  status: state.status,
  agent_type: state.agent_type,
  branch: state.branch,
  workdir: state.workdir,
  activity: state.activity,
  agents: state.agents,
  started_at: state.started_at,
  summary: state.summary
}
```

In `handle_info({:session_update, ...})` (line 254-286), add `summary`:

```elixir
session_map = %{
  session_id: new_state.session_id,
  name: new_state.name,
  status: new_state.status,
  agent_type: new_state.agent_type,
  branch: new_state.branch,
  workdir: new_state.workdir,
  activity: new_state.activity,
  agents: new_state.agents,
  started_at: new_state.started_at,
  summary: new_state.summary
}
```

In ghost session creation (line 18-36), set `summary: "Disconnected"`.

**Step 2: Update template to use summary field**

In the sessions panel template (around line 717), replace:
```heex
<div class="session-card-summary" title={raw_session_summary_text(state)}>
  {session_summary_text(state)}
</div>
```

With:
```heex
<div class="session-card-summary" title={state.summary || "Awaiting summary..."}>
  {sanitize_text(state.summary || "Awaiting summary...")}
</div>
```

**Step 3: Remove dead helper functions**

Delete `session_summary_text/1` and `raw_session_summary_text/1` (lines 378-398).

**Step 4: Run full test suite**

Run: `mix test --seed 0`
Expected: All tests pass

**Step 5: Commit**

```bash
git add lib/sam_web/live/dashboard_live.ex
git commit -m "fix: session cards use dedicated summary field instead of filtering activity"
```

---

### Task 4: Auto-Register Hooks on Startup

**Files:**
- Modify: `lib/sam/application.ex:9-28`
- Modify: `lib/sam/hooks/claude_code_hooks.ex:23-69`

**Step 1: Make register_hooks! idempotent**

Replace `register_hooks!` with `ensure_registered!` in `lib/sam/hooks/claude_code_hooks.ex`:

```elixir
def ensure_registered! do
  case check_and_prompt() do
    :already_registered ->
      Logger.info("[Hooks] SAM hooks already registered in Claude settings")
      :ok

    _ ->
      Logger.info("[Hooks] Registering SAM hooks in Claude settings")
      do_register!()
  end
end

defp do_register! do
  # (move the body of current register_hooks! here, but also create the hooks directory)
  hooks_dir = Path.join(System.user_home!(), ".claude/hooks")
  File.mkdir_p!(hooks_dir)

  content =
    case File.read(@settings_path) do
      {:ok, c} -> c
      {:error, :enoent} -> "{}"
    end

  settings = Jason.decode!(content)
  hooks = Map.get(settings, "hooks", %{})

  hook_script = hook_script_path()
  File.write!(hook_script, hook_script_content())
  File.chmod!(hook_script, 0o755)

  pre_hook_entry = %{
    "hooks" => [
      %{
        "type" => "command",
        "command" => "#{hook_script} pre_tool_call"
      }
    ]
  }

  post_hook_entry = %{
    "hooks" => [
      %{
        "type" => "command",
        "command" => "#{hook_script} post_tool_call"
      }
    ]
  }

  pre_tool = Map.get(hooks, "PreToolUse", [])
  post_tool = Map.get(hooks, "PostToolUse", [])

  updated_hooks =
    hooks
    |> Map.put("PreToolUse", pre_tool ++ [pre_hook_entry])
    |> Map.put("PostToolUse", post_tool ++ [post_hook_entry])

  updated_settings = Map.put(settings, "hooks", updated_hooks)

  File.write!(@settings_path, Jason.encode!(updated_settings, pretty: true))
  :ok
end
```

Add `require Logger` at top of module.

**Step 2: Call from Application.start**

In `lib/sam/application.ex`, add after `Supervisor.start_link`:

```elixir
def start(_type, _args) do
  children = [
    # ... existing children ...
  ]

  opts = [strategy: :one_for_one, name: Sam.Supervisor]
  result = Supervisor.start_link(children, opts)

  # Register hooks after app is running (non-critical — don't crash on failure)
  Task.start(fn ->
    try do
      Sam.Hooks.ClaudeCodeHooks.ensure_registered!()
    rescue
      e -> Logger.warning("[Hooks] Failed to register: #{inspect(e)}")
    end
  end)

  result
end
```

**Step 3: Verify hooks are installed**

Run: `mix test --seed 0`
Expected: All tests pass (hook registration is a side effect, not directly tested here)

**Step 4: Commit**

```bash
git add lib/sam/application.ex lib/sam/hooks/claude_code_hooks.ex
git commit -m "feat: auto-register Claude Code hooks on app startup"
```

---

### Task 5: Update Persistence to Include Summary

**Files:**
- Modify: `lib/sam/persistence.ex:55-61`

**Step 1: Add summary to serialized data**

In `flush_sessions/1`, update the serializable map:

```elixir
serializable = %{
  session_id: state.session_id,
  name: state.name,
  status: state.status,
  agent_type: state.agent_type,
  workdir: state.workdir,
  activity: Enum.take(state.activity, 50),
  summary: state.summary
}
```

**Step 2: Run full test suite**

Run: `mix precommit`
Expected: All pass

**Step 3: Commit**

```bash
git add lib/sam/persistence.ex
git commit -m "feat: persist session summary field to DETS"
```

---

### Task 6: Integration Verification

**Step 1: Run precommit**

Run: `mix precommit`
Expected: Compile (no warnings), format clean, all tests pass

**Step 2: Verify hooks installed**

Run: `cat ~/.claude/settings.json | python3 -m json.tool | grep -A5 sam-hook`
Expected: See PreToolUse and PostToolUse entries referencing sam-hook.sh

**Step 3: Restart server and verify no ghosts**

Run: Stop and restart `mix phx.server`
Expected: No ghost terminals in the UI

**Step 4: Create a session through SAM UI, observe status changes**

Create a Claude Code session, give it a task, watch status change from idle → working → idle.

**Step 5: Verify sessions panel shows different content from activity feed**

Switch to SESSIONS tab. Session cards should show latest summary text. Activity tab should show chronological log. They should be different.
