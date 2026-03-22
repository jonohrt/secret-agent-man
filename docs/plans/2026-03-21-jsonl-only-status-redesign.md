# JSONL-Only Status Redesign + Session Stability

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the flaky dual-channel (hooks + JSONL) status system with a reliable JSONL-only architecture, modeled on pixel-agents' proven approach, and fix session loss bugs.

**Architecture:** Pass `--session-id <uuid>` when spawning Claude Code so the JSONL path is deterministic. TranscriptWatcher becomes the sole status source. Drop hooks, JournalFinder, and Parser. Simplify to 4 states: working, idle, needs_input, done/error. Fix session stability bugs in Persistence, terminal.js, and DashboardLive.

**Tech Stack:** Elixir/Phoenix LiveView, xterm.js, Claude Code CLI (`--session-id` flag)

---

## Task 1: Pass `--session-id` to Claude Code and construct deterministic JSONL path

The foundation of everything. Generate a UUID for each session, pass it as `--session-id` to Claude Code, and store the expected JSONL path so TranscriptWatcher can use it directly.

**Files:**
- Modify: `lib/sam/agents/claude_code.ex`
- Modify: `lib/sam/agents/behaviour.ex`
- Modify: `lib/sam/agents/generic.ex`
- Modify: `lib/sam/agents/mock.ex`
- Modify: `lib/sam/session/group_supervisor.ex`
- Test: `test/sam/agents/claude_code_test.exs` (create)

**Step 1: Write the failing test**

Create `test/sam/agents/claude_code_test.exs`:

```elixir
defmodule Sam.Agents.ClaudeCodeTest do
  use ExUnit.Case, async: true

  describe "spawn_command/3" do
    test "includes --session-id flag" do
      {cmd, _uuid} = Sam.Agents.ClaudeCode.spawn_command("/tmp", nil)
      assert "--session-id" in cmd
    end

    test "returns a valid UUID as second element" do
      {_cmd, uuid} = Sam.Agents.ClaudeCode.spawn_command("/tmp", nil)
      # UUID v4 format: 8-4-4-4-12 hex chars
      assert Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/, uuid)
    end

    test "includes prompt when provided" do
      {cmd, _uuid} = Sam.Agents.ClaudeCode.spawn_command("/tmp", "fix the bug")
      assert List.last(cmd) == "fix the bug"
      assert "--session-id" in cmd
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/sam/agents/claude_code_test.exs -v`
Expected: FAIL — `spawn_command/3` doesn't exist (current is `spawn_command/2` returning just a list)

**Step 3: Update the behaviour and all adapters**

Change `lib/sam/agents/behaviour.ex`:

```elixir
defmodule Sam.Agents.Behaviour do
  @callback spawn_command(workdir :: String.t(), prompt :: String.t() | nil) ::
              {command :: [String.t()], claude_session_id :: String.t() | nil}
  @callback detect_running?() :: boolean()
  @callback parse_tier() :: :hooks | :stream | :llm
end
```

Change `lib/sam/agents/claude_code.ex`:

```elixir
defmodule Sam.Agents.ClaudeCode do
  @behaviour Sam.Agents.Behaviour

  @impl true
  def spawn_command(_workdir, prompt) do
    uuid = generate_uuid()
    base = ["claude", "--session-id", uuid, "--dangerously-skip-permissions"]
    cmd = if prompt && prompt != "", do: base ++ [prompt], else: base
    {cmd, uuid}
  end

  @impl true
  def detect_running? do
    case System.cmd("pgrep", ["-f", "claude"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  @impl true
  def parse_tier, do: :jsonl

  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    # Set version 4 and variant bits
    c = (c &&& 0x0FFF) ||| 0x4000
    d = (d &&& 0x3FFF) ||| 0x8000
    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end
end
```

Change `lib/sam/agents/generic.ex` — return `{cmd, nil}` tuple:

```elixir
def spawn_command(_workdir, _prompt) do
  {["/bin/bash", "-l"], nil}
end
```

Change `lib/sam/agents/mock.ex` — return `{cmd, nil}` tuple (match whatever its current return shape is).

**Step 4: Update GroupSupervisor to unpack the tuple and pass `claude_session_id` to children**

In `lib/sam/session/group_supervisor.ex`, update the `init/1` to:
- Call the adapter to get `{command, claude_session_id}`
- OR receive `command` and `claude_session_id` as separate opts (since `agent_command` is called in DashboardLive)

The cleaner approach: update `DashboardLive.agent_command/3` to return `{command, claude_session_id}` and pass both through opts.

In `lib/sam_web/live/dashboard_live.ex`, update `agent_command/3`:

```elixir
defp agent_command(agent_type, workdir, prompt) do
  adapter = agent_adapter(agent_type)
  adapter.spawn_command(workdir, prompt)
end
```

And all call sites that use it — `create_session` and `restart_session` — to unpack:

```elixir
{command, claude_session_id} = agent_command(agent_type, workdir, prompt)

Sam.Session.GroupSupervisor.start_session(%{
  session_id: session_id,
  name: ...,
  agent_type: agent_type,
  workdir: workdir,
  command: command,
  claude_session_id: claude_session_id
})
```

In `GroupSupervisor.init/1`, extract `claude_session_id` from opts and pass it to TranscriptWatcher:

```elixir
claude_session_id = Map.get(opts, :claude_session_id)

# TranscriptWatcher child spec:
%{
  id: Sam.Session.TranscriptWatcher,
  start:
    {Sam.Session.TranscriptWatcher, :start_link,
     [%{session_id: session_id, workdir: Map.get(opts, :workdir), claude_session_id: claude_session_id}]}
}
```

**Step 5: Run test to verify it passes**

Run: `mix test test/sam/agents/claude_code_test.exs -v`
Expected: PASS

**Step 6: Run full test suite**

Run: `mix test`
Expected: Some failures in existing tests that call `spawn_command/2` — those will be fixed in subsequent tasks. Note them but don't fix yet.

**Step 7: Commit**

```bash
git add lib/sam/agents/ test/sam/agents/ lib/sam/session/group_supervisor.ex lib/sam_web/live/dashboard_live.ex
git commit -m "feat: pass --session-id to Claude Code for deterministic JSONL path"
```

---

## Task 2: Make TranscriptWatcher use deterministic JSONL path (eliminate JournalFinder)

TranscriptWatcher currently waits for JournalFinder to send `{:journal_found, path}`. Instead, construct the path from `claude_session_id` and poll for it to appear.

**Files:**
- Modify: `lib/sam/session/transcript_watcher.ex`
- Modify: `test/sam/session/transcript_watcher_test.exs`

**Step 1: Write the failing test**

Add to `test/sam/session/transcript_watcher_test.exs`:

```elixir
@tag :tmp_dir
test "constructs deterministic JSONL path from claude_session_id", %{tmp_dir: tmp_dir} do
  session_id = "test-det-#{System.unique_integer([:positive])}"
  claude_session_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

  # Create the expected JSONL file
  project_dir = Path.join(tmp_dir, "project")
  File.mkdir_p!(project_dir)
  jsonl_path = Path.join(project_dir, "#{claude_session_id}.jsonl")
  File.write!(jsonl_path, "")

  Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

  {:ok, pid} =
    GenServer.start_link(Sam.Session.TranscriptWatcher, %{
      session_id: session_id,
      workdir: nil,
      claude_session_id: claude_session_id,
      _test_project_dir: project_dir
    })

  # Give it time to find the file
  Process.sleep(1500)

  # Append data — should emit events
  record =
    Jason.encode!(%{
      "message" => %{
        "role" => "assistant",
        "content" => [%{"type" => "tool_use", "id" => "t1", "name" => "Read", "input" => %{}}]
      }
    })

  File.write!(jsonl_path, record <> "\n", [:append])
  assert_receive {:parser_event, ^session_id, %{type: :tool_call, tool: "Read"}}, 3000

  GenServer.stop(pid)
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/sam/session/transcript_watcher_test.exs -v`
Expected: FAIL — TranscriptWatcher ignores `claude_session_id`

**Step 3: Update TranscriptWatcher init to construct path**

In `lib/sam/session/transcript_watcher.ex`, update `init/1`:

```elixir
@impl true
def init(opts) do
  session_id = Map.fetch!(opts, :session_id)
  workdir = Map.get(opts, :workdir)
  claude_session_id = Map.get(opts, :claude_session_id)
  test_path = Map.get(opts, :_test_jsonl_path)
  test_project_dir = Map.get(opts, :_test_project_dir)

  # Determine the expected JSONL path
  path =
    cond do
      # Direct test path (existing tests)
      test_path != nil ->
        test_path

      # Deterministic path from claude_session_id
      claude_session_id != nil ->
        dir = test_project_dir || project_dir(workdir)
        Path.join(dir, "#{claude_session_id}.jsonl")

      # Fallback: no path (legacy, will wait for journal_found)
      true ->
        nil
    end

  # If we have a deterministic path but file doesn't exist yet, set path but poll will wait
  state = %{
    session_id: session_id,
    workdir: workdir,
    path: path,
    offset: if(path && File.exists?(path), do: file_size(path), else: 0),
    line_buffer: "",
    waiting_for_file: path != nil && !File.exists?(path)
  }

  send(self(), :poll)
  {:ok, state}
end
```

Update the poll handler to handle `waiting_for_file`:

```elixir
@impl true
def handle_info(:poll, %{waiting_for_file: true, path: path} = state) when path != nil do
  if File.exists?(path) do
    Logger.info("[TranscriptWatcher] JSONL file appeared: #{Path.basename(path)}")
    offset = file_size(path)
    schedule_poll()
    {:noreply, %{state | waiting_for_file: false, offset: offset}}
  else
    schedule_poll()
    {:noreply, state}
  end
end
```

**Step 4: Run test to verify it passes**

Run: `mix test test/sam/session/transcript_watcher_test.exs -v`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/sam/session/transcript_watcher.ex test/sam/session/transcript_watcher_test.exs
git commit -m "feat: TranscriptWatcher uses deterministic JSONL path from claude_session_id"
```

---

## Task 3: Add `turn_duration` as definitive idle signal and `needs_input` heuristic

Currently TranscriptWatcher emits `:tool_result` for `turn_duration`, and Server uses timers for idle. Replace with: `turn_duration` → immediate `:idle`. Add 7s silence heuristic for `:needs_input`.

**Files:**
- Modify: `lib/sam/session/transcript_watcher.ex`
- Modify: `lib/sam/session/server.ex`
- Modify: `test/sam/session/server_test.exs`
- Modify: `test/sam/session/transcript_watcher_test.exs`

**Step 1: Write failing test for turn_end → immediate idle**

Add to `test/sam/session/server_test.exs`:

```elixir
describe "JSONL-driven status" do
  setup do
    session_id = "test-jsonl-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")

    {:ok, pid} =
      GenServer.start_link(Sam.Session.Server, %{
        session_id: session_id,
        name: "JSONL Test",
        idle_timeout_ms: 100
      })

    assert_receive {:session_update, ^session_id, %{status: :idle}}, 1000
    %{session_id: session_id, pid: pid}
  end

  test "turn_end event transitions immediately to :idle (no timer)", %{
    session_id: id,
    pid: pid
  } do
    # Start working
    send(pid, {:parser_event, id, %{type: :tool_call, tool: "Read", timestamp: DateTime.utc_now()}})
    assert_receive {:session_update, ^id, %{status: :working}}, 1000

    # turn_end = immediate idle, no waiting for timer
    send(pid, {:parser_event, id, %{type: :turn_end, timestamp: DateTime.utc_now()}})
    assert_receive {:session_update, ^id, %{status: :idle}}, 500
  end

  test "needs_input_timeout fires after silence during tool execution", %{
    session_id: id,
    pid: pid
  } do
    # Start working with a non-exempt tool
    send(pid, {:parser_event, id, %{
      type: :tool_call,
      tool: "Bash",
      timestamp: DateTime.utc_now()
    }})
    assert_receive {:session_update, ^id, %{status: :working}}, 1000

    # After needs_input_timeout_ms (set to 200ms in test), should go to needs_input
    # We need to configure this in the test setup — add needs_input_timeout_ms: 200
    # For now, the default 7000ms is too long for tests.
    # This test will be refined when we implement the feature.
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/sam/session/server_test.exs -v`
Expected: FAIL — Server doesn't handle `:turn_end` event type

**Step 3: Update TranscriptWatcher to emit `:turn_end` instead of `:tool_result` for turn_duration**

In `lib/sam/session/transcript_watcher.ex`, change `handle_record` for turn_duration:

```elixir
defp handle_record(%{"type" => "system", "subtype" => "turn_duration"}, session_id) do
  Phoenix.PubSub.broadcast(
    Sam.PubSub,
    "session:#{session_id}",
    {:parser_event, session_id,
     %{type: :turn_end, timestamp: DateTime.utc_now()}}
  )
end
```

**Step 4: Update Server to handle `:turn_end` as immediate idle**

In `lib/sam/session/server.ex`, add a new handler:

```elixir
@impl true
def handle_info({:parser_event, _, %{type: :turn_end}}, state) do
  if state.status in [:done, :error] do
    {:noreply, state}
  else
    state = cancel_idle_timer(state)
    state = cancel_needs_input_timer(state)
    state = %{state | status: :idle}
    broadcast_ui_update(state)
    {:noreply, state}
  end
end
```

Also add `:needs_input_timer` to the struct and a 7s silence heuristic. When a non-exempt tool starts, start a needs_input timer. If no new JSONL data arrives within 7s, transition to `:needs_input`. Cancel it when any new parser event arrives.

Add to struct: `needs_input_timer: nil, needs_input_timeout_ms: 7_000`

In tool_call handler, after setting `:working`, start needs_input timer for non-exempt tools:

```elixir
# Exempt tools that don't need permission (Agent, Task spawn their own subprocesses)
@permission_exempt_tools ~w(Agent Task AskUserQuestion)

# In tool_call handler, after setting status to :working:
state =
  if tool not in @permission_exempt_tools do
    cancel_needs_input_timer(state)
    |> start_needs_input_timer()
  else
    cancel_needs_input_timer(state)
  end
```

In tool_result handler, cancel the needs_input timer:

```elixir
state = cancel_needs_input_timer(state)
```

Add the timer handler:

```elixir
@impl true
def handle_info(:needs_input_timeout, state) do
  if state.status == :working do
    state = %{state | status: :needs_input, needs_input_timer: nil}
    broadcast_ui_update(state)
    {:noreply, state}
  else
    {:noreply, %{state | needs_input_timer: nil}}
  end
end
```

**Step 5: Run test to verify it passes**

Run: `mix test test/sam/session/server_test.exs -v`
Expected: PASS

**Step 6: Update TranscriptWatcher tests for new event type**

Update the `turn_duration` test in `test/sam/session/transcript_watcher_test.exs`:

```elixir
# Change expected event type from :tool_result to :turn_end
assert_receive {:parser_event, ^session_id, %{type: :turn_end}}, 3000
```

**Step 7: Run full test suite**

Run: `mix test`
Expected: PASS (or note remaining failures from hook removal — Task 4)

**Step 8: Commit**

```bash
git add lib/sam/session/server.ex lib/sam/session/transcript_watcher.ex test/sam/session/server_test.exs test/sam/session/transcript_watcher_test.exs
git commit -m "feat: turn_duration as definitive idle signal, 7s needs_input heuristic"
```

---

## Task 4: Remove hooks infrastructure

Remove the hook endpoint, hook_event handling in Server, and Parser (its only remaining job was parsing hook events and detecting input_needed from PTY output — input_needed detection moves to TranscriptWatcher's silence heuristic).

**Files:**
- Delete: `lib/sam_web/controllers/hook_controller.ex`
- Delete: `lib/sam/session/parser.ex`
- Delete: `test/sam/session/parser_test.exs`
- Modify: `lib/sam_web/router.ex`
- Modify: `lib/sam/session/server.ex`
- Modify: `lib/sam/session/group_supervisor.ex`
- Modify: `test/sam/session/server_test.exs`

**Step 1: Remove hook route**

In `lib/sam_web/router.ex`, remove:

```elixir
post "/hooks", HookController, :create
```

**Step 2: Remove hook_event handling from Server**

In `lib/sam/session/server.ex`:
- Remove `push_hook_event/2` public function
- Remove `handle_cast({:hook_event, event}, state)` handler
- Remove `:pre_tool_call` and `:post_tool_call` from tool_call/tool_result handler guards (keep `:tool_call` and `:tool_result` which come from TranscriptWatcher)

Update handler:

```elixir
# Before: when type in [:tool_call, :pre_tool_call]
# After:
@impl true
def handle_info({:parser_event, _, %{type: :tool_call} = event}, state) do
  # ... existing logic ...
end

# Before: when type in [:tool_result, :post_tool_call]
# After:
@impl true
def handle_info({:parser_event, _, %{type: :tool_result} = event}, state) do
  # ... existing logic ...
end
```

**Step 3: Remove Parser from GroupSupervisor children**

In `lib/sam/session/group_supervisor.ex`, remove the Parser child spec:

```elixir
# Remove this entire block:
%{
  id: Sam.Session.Parser,
  start: {Sam.Session.Parser, :start_link, [%{session_id: session_id}]}
},
```

**Step 4: Delete files**

```bash
rm lib/sam_web/controllers/hook_controller.ex
rm lib/sam/session/parser.ex
rm test/sam/session/parser_test.exs
```

**Step 5: Update Server tests to remove hook-specific test names**

In `test/sam/session/server_test.exs`, rename the describe block:

```elixir
# Before: describe "hook-event status detection" do
# After:
describe "JSONL event status detection" do
```

Remove the `pre_tool_call` / `post_tool_call` tests since those event types no longer exist. Keep `tool_call` and `tool_result` tests.

**Step 6: Remove `send_input` Enter-key detection from Server**

The 30-second fallback timer on Enter press was a workaround for hooks not firing. With JSONL-only, remove this — TranscriptWatcher will detect the assistant response.

In `lib/sam/session/server.ex`, simplify `handle_cast({:send_input, data}, state)`:

```elixir
@impl true
def handle_cast({:send_input, data}, state) do
  if state.status in [:done, :error] do
    {:noreply, state}
  else
    Phoenix.PubSub.broadcast(Sam.PubSub, "session_input:#{state.session_id}", {:input, data})
    {:noreply, state}
  end
end
```

**Step 7: Run full test suite**

Run: `mix test`
Expected: PASS — all hook references cleaned up

**Step 8: Compile check**

Run: `mix compile --warnings-as-errors`
Expected: PASS — no warnings about removed modules

**Step 9: Commit**

```bash
git add -A
git commit -m "refactor: remove hooks infrastructure, Parser — JSONL is sole status source"
```

---

## Task 5: Remove JournalFinder

JournalFinder is no longer needed — TranscriptWatcher constructs its own path.

**Files:**
- Delete: `lib/sam/session/journal_finder.ex`
- Delete: `test/sam/session/journal_finder_test.exs`
- Modify: `lib/sam/session/group_supervisor.ex`
- Modify: `lib/sam/session/transcript_watcher.ex`

**Step 1: Remove JournalFinder from GroupSupervisor children**

In `lib/sam/session/group_supervisor.ex`, remove:

```elixir
%{
  id: Sam.Session.JournalFinder,
  start:
    {Sam.Session.JournalFinder, :start_link,
     [%{session_id: session_id, watch_dir: journal_watch_dir(Map.get(opts, :workdir))}]},
  restart: :temporary
}
```

Also remove the `journal_watch_dir/1` helper functions since they're no longer needed.

**Step 2: Remove `handle_info({:journal_found, path})` from TranscriptWatcher**

In `lib/sam/session/transcript_watcher.ex`, remove:

```elixir
def handle_info({:journal_found, path}, state) do
  Logger.info("[TranscriptWatcher] Received journal path: #{Path.basename(path)}")
  offset = file_size(path)
  {:noreply, %{state | path: path, offset: offset}}
end
```

**Step 3: Delete files**

```bash
rm lib/sam/session/journal_finder.ex
rm test/sam/session/journal_finder_test.exs
```

**Step 4: Run full test suite**

Run: `mix test`
Expected: PASS

**Step 5: Commit**

```bash
git add -A
git commit -m "refactor: remove JournalFinder — TranscriptWatcher constructs path directly"
```

---

## Task 6: Simplify status states to 4 (drop :background)

Remove `:background` state. When idle timer fires during `:working`, just stay `:working` if subagents are running (or go `:idle` if not).

**Files:**
- Modify: `lib/sam/session/server.ex`
- Modify: `test/sam/session/server_test.exs`
- Modify: `lib/sam_web/live/dashboard_live.ex` (remove :background CSS references)

**Step 1: Write failing test**

Add to `test/sam/session/server_test.exs`:

```elixir
test "idle timeout goes directly to :idle, never :background", %{session_id: id, pid: pid} do
  # Start working with an Agent tool (creates subagent)
  send(pid, {:parser_event, id, %{
    type: :tool_call,
    tool: "Agent",
    description: "test agent",
    timestamp: DateTime.utc_now()
  }})
  assert_receive {:session_update, ^id, %{status: :working}}, 1000

  # Tool result (but agent still "working" in our tracking)
  send(pid, {:parser_event, id, %{
    type: :tool_result,
    tool: "Read",
    timestamp: DateTime.utc_now()
  }})

  # After idle timeout, should be :idle, NOT :background
  assert_receive {:session_update, ^id, %{status: :idle}}, 1000
  refute_receive {:session_update, ^id, %{status: :background}}, 200
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/sam/session/server_test.exs -v`
Expected: FAIL — Server transitions to `:background` when subagents exist

**Step 3: Simplify idle_timeout handler**

In `lib/sam/session/server.ex`, replace `handle_info(:idle_timeout, ...)`:

```elixir
@impl true
def handle_info(:idle_timeout, state) do
  if state.status == :working do
    state = %{state | status: :idle, idle_timer: nil}
    broadcast_ui_update(state)
    {:noreply, state}
  else
    {:noreply, %{state | idle_timer: nil}}
  end
end
```

Remove all `:background` references from:
- `handle_cast({:send_input, ...})` — remove `:background` from the status check
- `handle_info({:parser_event, _, %{type: type} = event})` for tool_result — remove the `:background` special case

**Step 4: Run test to verify it passes**

Run: `mix test test/sam/session/server_test.exs -v`
Expected: PASS

**Step 5: Clean up UI references**

In `lib/sam_web/live/dashboard_live.ex`:
- `status_class/1` — remove `:background` clause (will fall through to default)

In `assets/css/themes.css` (if it has `.background` styles) — leave them, they won't hurt.

**Step 6: Run full test suite**

Run: `mix test`
Expected: PASS

**Step 7: Commit**

```bash
git add lib/sam/session/server.ex test/sam/session/server_test.exs lib/sam_web/live/dashboard_live.ex
git commit -m "refactor: simplify to 4 status states, drop :background"
```

---

## Task 7: Fix session stability — Persistence cleanup_stale

The `cleanup_stale/1` function nukes ALL DETS records on every server start. Replace with selective cleanup.

**Files:**
- Modify: `lib/sam/persistence.ex`
- Test: `test/sam/persistence_test.exs` (create)

**Step 1: Write failing test**

Create `test/sam/persistence_test.exs`:

```elixir
defmodule Sam.PersistenceTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "cleanup_stale only removes sessions not currently running", %{tmp_dir: tmp_dir} do
    dets_path = Path.join(tmp_dir, "test_sessions") |> to_charlist()
    {:ok, table} = :dets.open_file(:test_persist, file: dets_path, type: :set)

    # Insert two sessions
    :dets.insert(table, {"alive-session", %{session_id: "alive-session", name: "Alive"}})
    :dets.insert(table, {"dead-session", %{session_id: "dead-session", name: "Dead"}})

    # cleanup_stale should only remove sessions not in the running list
    Sam.Persistence.cleanup_stale(table, ["alive-session"])

    remaining = :dets.foldl(fn {id, _}, acc -> [id | acc] end, [], table)
    assert "alive-session" in remaining
    refute "dead-session" in remaining

    :dets.close(table)
  end
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/sam/persistence_test.exs -v`
Expected: FAIL — `cleanup_stale/2` doesn't accept a running list

**Step 3: Fix cleanup_stale**

In `lib/sam/persistence.ex`:

```elixir
def cleanup_stale(table \\ :sam_persistence, running_ids \\ []) do
  :dets.foldl(
    fn {id, _data}, acc ->
      if id in running_ids, do: acc, else: [id | acc]
    end,
    [],
    table
  )
  |> Enum.each(fn id -> :dets.delete(table, id) end)
rescue
  ArgumentError -> :ok
end
```

Update `init/1` to pass currently running session IDs:

```elixir
def init(_) do
  dets_path = Path.join(data_dir(), "sam_sessions") |> to_charlist()
  {:ok, table} = :dets.open_file(:sam_persistence, file: dets_path, type: :set)
  # Only clean up sessions that are truly not running
  running = Sam.Session.Server.list_sessions()
  cleanup_stale(table, running)
  schedule_flush()
  {:ok, %{table: table}}
end
```

**Step 4: Run test to verify it passes**

Run: `mix test test/sam/persistence_test.exs -v`
Expected: PASS

**Step 5: Run full test suite**

Run: `mix test`
Expected: PASS

**Step 6: Commit**

```bash
git add lib/sam/persistence.ex test/sam/persistence_test.exs
git commit -m "fix: cleanup_stale only removes sessions not currently running"
```

---

## Task 8: Fix session stability — terminal.js channel join retry

When channel join fails, the hook silently gives up and deletes from cache. Add retry logic.

**Files:**
- Modify: `assets/js/terminal.js`

**Step 1: Add retry logic to channel join**

In `assets/js/terminal.js`, replace the `.receive('error', ...)` handler:

```javascript
// Retry logic for channel join
const MAX_JOIN_RETRIES = 3
const JOIN_RETRY_DELAY_MS = 2000
let joinRetries = 0

const attemptJoin = () => {
  this.channel.join()
    .receive('ok', () => {
      joinRetries = 0
      console.log(`Connected to terminal:${sessionId}`)
      if (this.el.style.display !== 'none') {
        this.fitAddon.fit()
        const dims = this.fitAddon.proposeDimensions()
        if (dims) {
          this.channel.push('resize', { cols: dims.cols, rows: dims.rows })
        }
      }
    })
    .receive('error', (resp) => {
      joinRetries++
      if (joinRetries <= MAX_JOIN_RETRIES) {
        console.warn(`Channel join failed for terminal:${sessionId} (attempt ${joinRetries}/${MAX_JOIN_RETRIES}), retrying in ${JOIN_RETRY_DELAY_MS}ms...`, resp)
        setTimeout(() => {
          this.channel.leave()
          this.channel = getSocket().channel(`terminal:${sessionId}`, {})
          attemptJoin()
        }, JOIN_RETRY_DELAY_MS)
      } else {
        console.error(`Failed to join terminal:${sessionId} after ${MAX_JOIN_RETRIES} retries`, resp)
        this.channel.leave()
        delete terminalCache[sessionId]
      }
    })
}
attemptJoin()
```

**Step 2: No automated test for this** (JS changes need manual verification)

**Step 3: Commit**

```bash
git add assets/js/terminal.js
git commit -m "fix: retry channel join 3 times before giving up on terminal connection"
```

---

## Task 9: Fix session stability — load_sessions error logging

Silent error swallowing in `load_sessions/0` drops sessions without any indication.

**Files:**
- Modify: `lib/sam_web/live/dashboard_live.ex`

**Step 1: Add logging to load_sessions**

In `lib/sam_web/live/dashboard_live.ex`, add `require Logger` at the top and update `load_sessions/0`:

```elixir
defp load_sessions do
  Sam.Session.Server.list_sessions()
  |> Enum.reduce(%{}, fn id, acc ->
    try do
      state = Sam.Session.Server.get_state(id)

      session_map = %{
        session_id: state.session_id,
        name: state.name,
        status: state.status,
        agent_type: state.agent_type,
        branch: state.branch,
        workdir: state.workdir,
        activity: state.activity,
        agents: state.agents,
        started_at: state.started_at
      }

      Map.put(acc, id, session_map)
    rescue
      e ->
        Logger.warning("[DashboardLive] Failed to load session #{id}: #{inspect(e)}")
        acc
    catch
      :exit, reason ->
        Logger.warning("[DashboardLive] Session #{id} not responding: #{inspect(reason)}")
        acc
    end
  end)
end
```

**Step 2: No test needed for logging**

**Step 3: Commit**

```bash
git add lib/sam_web/live/dashboard_live.ex
git commit -m "fix: log errors when loading sessions instead of silent swallow"
```

---

## Task 10: Final verification and cleanup

**Step 1: Run precommit**

Run: `mix precommit`
Expected: PASS (compile, format, test all green)

**Step 2: Check for dead code references**

Run: `grep -r "hook_event\|push_hook_event\|HookController\|JournalFinder\|:background\|:pre_tool_call\|:post_tool_call\|parse_hook_event" lib/ test/ --include="*.ex" --include="*.exs"`

Expected: No matches (or only in this plan file / docs)

**Step 3: Verify TranscriptWatcher test coverage**

Run: `mix test test/sam/session/transcript_watcher_test.exs test/sam/session/server_test.exs -v`
Expected: All pass

**Step 4: Restart Phoenix server and test manually**

```bash
mix phx.server
```

1. Create a new Claude Code session
2. Observe that status changes from `:idle` → `:working` when Claude uses tools
3. Observe that status goes to `:idle` when `turn_duration` fires (Claude finishes a turn)
4. Observe that status goes to `:needs_input` if a tool takes >7s (permission prompt)
5. Verify sessions survive tab switching (no disappearance)

**Step 5: Final commit if any cleanup needed**

```bash
git add -A
git commit -m "chore: final cleanup after JSONL-only status redesign"
```

---

## Summary of what gets deleted vs created

### Deleted
- `lib/sam_web/controllers/hook_controller.ex`
- `lib/sam/session/parser.ex`
- `lib/sam/session/journal_finder.ex`
- `test/sam/session/parser_test.exs`
- `test/sam/session/journal_finder_test.exs`
- Hook route in router
- `:background` status state
- Enter-key working detection in Server
- 30s fallback timer in Server

### Created
- `test/sam/agents/claude_code_test.exs`
- `test/sam/persistence_test.exs`

### Modified (key changes)
- `lib/sam/agents/claude_code.ex` — `--session-id` flag, UUID generation
- `lib/sam/session/transcript_watcher.ex` — deterministic path, `waiting_for_file` state
- `lib/sam/session/server.ex` — `:turn_end` handler, needs_input timer, simplified states
- `lib/sam/session/group_supervisor.ex` — remove Parser/JournalFinder children, pass claude_session_id
- `lib/sam/persistence.ex` — selective cleanup_stale
- `assets/js/terminal.js` — channel join retry
- `lib/sam_web/live/dashboard_live.ex` — error logging in load_sessions
