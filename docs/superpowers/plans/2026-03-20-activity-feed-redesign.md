# Activity Feed Redesign + Dashboard Bug Fixes

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the noisy tool-name activity feed with LLM-generated intent summaries (via local Ollama/Gemma 3 4B) and fix three dashboard bugs (missing agent titles, broken branch display, frozen elapsed time).

**Architecture:** Rewrite the Summarizer GenServer backend to call a new `Sam.LLM.Ollama` HTTP client, falling back to heuristic labels when Ollama is unavailable. Wire Summarizer output into Server's activity feed (currently ignored). Fix Server struct to include `started_at` and populate `branch` via git. Add a LiveView tick timer for elapsed time.

**Tech Stack:** Elixir/Phoenix LiveView, Ollama REST API, Gemma 3 4B, DETS settings

**Spec:** `docs/superpowers/specs/2026-03-20-activity-feed-redesign-design.md`

---

## File Structure

| File | Responsibility |
|------|---------------|
| `lib/sam/llm/ollama.ex` | NEW — Ollama HTTP client: health check, model detection, chat summarization |
| `lib/sam/llm/client.ex` | MODIFY — No longer called by Summarizer (kept for backwards compat, not touched) |
| `lib/sam/session/summarizer.ex` | MODIFY — Replace LLM.Client backend with Ollama + heuristic fallback |
| `lib/sam/session/server.ex` | MODIFY — Add `started_at`/`branch` to struct, wire summaries into activity, fix agent descriptions, remove raw `add_activity` from tool handlers |
| `lib/sam_web/live/dashboard_live.ex` | MODIFY — Handle `:summary` activity type, add tick timer for elapsed time |
| `test/sam/llm/ollama_test.exs` | NEW — Ollama client unit tests |
| `test/sam/session/summarizer_test.exs` | MODIFY — Test new Ollama + heuristic backends |
| `test/sam/session/server_test.exs` | MODIFY — Test summary wiring, started_at, branch, agent description fix |

---

### Task 1: Fix Agent Titles (Bug)

**Files:**
- Modify: `lib/sam/session/server.ex:160-172`
- Test: `test/sam/session/server_test.exs`

**Root cause:** Empty string `""` is truthy in Elixir, so `desc || "subagent"` doesn't catch empty descriptions from hook events.

- [ ] **Step 1: Write failing test**

```elixir
# In server_test.exs
test "agent entry gets fallback description when hook sends empty string" do
  session_id = "test-agent-title-#{System.unique_integer([:positive])}"
  opts = %{session_id: session_id}
  pid = start_supervised!({Sam.Session.Server, opts})

  # Simulate hook event with empty description for Agent tool
  event = %{
    type: :tool_call,
    tool: "Agent",
    description: "",
    file: nil,
    session_id: session_id,
    timestamp: DateTime.utc_now()
  }

  Phoenix.PubSub.broadcast(Sam.PubSub, "session:#{session_id}", {:parser_event, session_id, event})
  # Let GenServer process the message
  :sys.get_state(pid)

  state = Sam.Session.Server.get_state(session_id)
  agent = List.first(state.agents)
  assert agent.description == "subagent"
  assert agent.description != ""
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/sam/session/server_test.exs --seed 0 -v`
Expected: FAIL — agent.description is `""` not `"subagent"`

- [ ] **Step 3: Fix the empty string check in server.ex**

In `lib/sam/session/server.ex`, replace lines 160-172:

```elixir
state =
  if tool == "Agent" do
    agent_desc =
      case desc do
        d when is_binary(d) and d != "" -> d
        _ -> "subagent"
      end

    agent_entry = %{
      id: System.unique_integer([:positive]),
      description: agent_desc,
      status: :working,
      started_at: DateTime.utc_now()
    }

    %{state | agents: state.agents ++ [agent_entry]}
  else
    state
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/sam/session/server_test.exs --seed 0 -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/sam/session/server.ex test/sam/session/server_test.exs
git commit -m "fix: agent entries get fallback title when hook sends empty description"
```

---

### Task 2: Fix Branch Display (Bug)

**Files:**
- Modify: `lib/sam/session/server.ex:7-18,57-72`
- Test: `test/sam/session/server_test.exs`

**Root cause:** `branch` field exists in Server struct but is never populated during init.

- [ ] **Step 1: Write failing test**

```elixir
test "server populates branch from git on init" do
  session_id = "test-branch-#{System.unique_integer([:positive])}"
  # Use the actual working directory which is a git repo
  workdir = File.cwd!()
  opts = %{session_id: session_id, workdir: workdir}
  _pid = start_supervised!({Sam.Session.Server, opts})

  state = Sam.Session.Server.get_state(session_id)
  assert is_binary(state.branch)
  assert state.branch != ""
  assert state.branch != nil
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/sam/session/server_test.exs --seed 0 -v`
Expected: FAIL — `state.branch` is `nil`

- [ ] **Step 3: Add branch detection to Server init**

In `lib/sam/session/server.ex`, add a private function:

```elixir
defp detect_branch(workdir) when is_binary(workdir) do
  case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: workdir, stderr_to_stdout: true) do
    {branch, 0} -> String.trim(branch)
    _ -> nil
  end
rescue
  _ -> nil
end

defp detect_branch(_), do: nil
```

Then update `init/1` to populate branch:

```elixir
state = %__MODULE__{
  session_id: session_id,
  name: Map.get(opts, :name, session_id),
  agent_type: Map.get(opts, :agent_type, :generic),
  workdir: Map.get(opts, :workdir),
  branch: detect_branch(Map.get(opts, :workdir)),
  idle_timeout_ms: Map.get(opts, :idle_timeout_ms, @idle_timeout_ms),
  status: :idle
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/sam/session/server_test.exs --seed 0 -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/sam/session/server.ex test/sam/session/server_test.exs
git commit -m "fix: populate git branch in server state on init"
```

---

### Task 3: Fix Elapsed Time (Bug)

**Files:**
- Modify: `lib/sam/session/server.ex:7-18,57-72` (add `started_at` to struct and init)
- Modify: `lib/sam_web/live/dashboard_live.ex:7-27,140-171` (add tick timer)
- Test: `test/sam/session/server_test.exs`

**Root cause:** Two issues: (1) Server struct has no `started_at` field, so `format_uptime/1` always returns "00:00:00". (2) No periodic timer in LiveView to trigger re-renders for the clock.

- [ ] **Step 1: Write failing test for started_at**

```elixir
test "server sets started_at on init" do
  session_id = "test-uptime-#{System.unique_integer([:positive])}"
  before = DateTime.utc_now()
  opts = %{session_id: session_id}
  _pid = start_supervised!({Sam.Session.Server, opts})

  state = Sam.Session.Server.get_state(session_id)
  assert %DateTime{} = state.started_at
  assert DateTime.compare(state.started_at, before) in [:gt, :eq]
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/sam/session/server_test.exs --seed 0 -v`
Expected: FAIL — `state.started_at` is nil (field doesn't exist in struct)

- [ ] **Step 3: Add started_at to Server struct and init**

In `lib/sam/session/server.ex`, add `:started_at` to the struct:

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
  agents: []
]
```

In `init/1`, set `started_at`:

```elixir
state = %__MODULE__{
  session_id: session_id,
  name: Map.get(opts, :name, session_id),
  agent_type: Map.get(opts, :agent_type, :generic),
  workdir: Map.get(opts, :workdir),
  branch: detect_branch(Map.get(opts, :workdir)),
  idle_timeout_ms: Map.get(opts, :idle_timeout_ms, @idle_timeout_ms),
  started_at: DateTime.utc_now(),
  status: :idle
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/sam/session/server_test.exs --seed 0 -v`
Expected: PASS

- [ ] **Step 5: Add started_at to session_map in dashboard_live.ex**

In `lib/sam_web/live/dashboard_live.ex`, add `started_at` to the session map in both `handle_info` (line 141-150) and `load_sessions` (line 185-194):

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
  started_at: new_state.started_at
}
```

- [ ] **Step 6: Add tick timer to LiveView mount**

In `lib/sam_web/live/dashboard_live.ex`, add a periodic timer in `mount/3` after the PubSub subscribe:

```elixir
if connected?(socket) do
  Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")
  :timer.send_interval(1_000, self(), :tick)
end
```

Add a handler:

```elixir
@impl true
def handle_info(:tick, socket) do
  {:noreply, assign(socket, tick: socket.assigns.tick + 1)}
end
```

The existing `tick` assign is already in the template's dependency graph (it's assigned in mount), so incrementing it every second forces a re-render, which recalculates `format_uptime/1`.

- [ ] **Step 7: Run all tests**

Run: `mix test --seed 0`
Expected: All pass

- [ ] **Step 8: Commit**

```bash
git add lib/sam/session/server.ex lib/sam_web/live/dashboard_live.ex test/sam/session/server_test.exs
git commit -m "fix: add started_at to session state and tick timer for elapsed time"
```

---

### Task 4: Ollama Client Module

**Files:**
- Create: `lib/sam/llm/ollama.ex`
- Create: `test/sam/llm/ollama_test.exs`

- [ ] **Step 1: Write tests for Ollama client**

```elixir
# test/sam/llm/ollama_test.exs
defmodule Sam.LLM.OllamaTest do
  use ExUnit.Case, async: true

  alias Sam.LLM.Ollama

  describe "heuristic_label/1" do
    test "uses description field when present" do
      events = [%{type: :tool_call, tool: "Bash", description: "Check beads for open issues"}]
      assert Ollama.heuristic_label(events) == "Check beads for open issues"
    end

    test "generates label from file path for Read" do
      events = [%{type: :tool_call, tool: "Read", file: "/lib/sam/session/server.ex"}]
      assert Ollama.heuristic_label(events) == "Reading server.ex"
    end

    test "generates label from pattern for Glob" do
      events = [%{type: :tool_call, tool: "Glob", pattern: "screenshots/**/*"}]
      assert Ollama.heuristic_label(events) == "Searching for screenshots/**/*"
    end

    test "groups multiple same-tool calls" do
      events = [
        %{type: :tool_call, tool: "Read", file: "/lib/sam/server.ex"},
        %{type: :tool_call, tool: "Read", file: "/lib/sam/parser.ex"},
        %{type: :tool_call, tool: "Read", file: "/lib/sam/summarizer.ex"}
      ]
      assert Ollama.heuristic_label(events) =~ "Reading 3 files"
    end

    test "falls back to tool name when no description or file" do
      events = [%{type: :tool_call, tool: "Bash"}]
      assert Ollama.heuristic_label(events) == "Bash"
    end

    test "uses Agent description" do
      events = [%{type: :tool_call, tool: "Agent", description: "Explore activity feed"}]
      assert Ollama.heuristic_label(events) == "Explore activity feed"
    end
  end

  describe "check_availability/0" do
    test "returns :unavailable when Ollama is not running" do
      # Default case — no mock, Ollama likely not on test CI
      result = Ollama.check_availability("http://localhost:99999")
      assert result == :unavailable
    end
  end

  describe "format_events_for_prompt/1" do
    test "formats tool call events into readable lines" do
      events = [
        %{type: :tool_call, tool: "Read", file: "/lib/sam/server.ex", description: nil},
        %{type: :tool_call, tool: "Bash", description: "Run tests"}
      ]
      result = Ollama.format_events_for_prompt(events)
      assert result =~ "Read"
      assert result =~ "server.ex"
      assert result =~ "Run tests"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/sam/llm/ollama_test.exs --seed 0 -v`
Expected: FAIL — module does not exist

- [ ] **Step 3: Implement Ollama client**

```elixir
# lib/sam/llm/ollama.ex
defmodule Sam.LLM.Ollama do
  @moduledoc """
  HTTP client for local Ollama instance. Provides LLM summarization
  of agent tool calls with heuristic fallback.
  """

  require Logger

  @default_base_url "http://localhost:11434"
  @timeout_ms 5_000
  @model_preference ["gemma3:4b", "gemma3:1b"]

  @summarize_prompt """
  You are summarizing a coding agent's actions for a dashboard activity feed.
  Given these tool calls, write one short sentence describing what the agent is doing.
  Be concise — 10 words or fewer preferred. Do not use quotes or markdown.
  """

  # --- Public API ---

  @doc "Check if Ollama is running and find best available model."
  def check_availability(base_url \\ @default_base_url) do
    case Req.get("#{base_url}/api/tags", receive_timeout: 2_000) do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        names = Enum.map(models, & &1["name"])
        find_preferred_model(names)

      _ ->
        :unavailable
    end
  rescue
    _ -> :unavailable
  end

  @doc "Summarize a batch of tool call events. Returns {:ok, text} or {:error, reason}."
  def summarize(events, model, base_url \\ @default_base_url) do
    prompt = format_events_for_prompt(events)

    body = %{
      model: model,
      messages: [
        %{role: "system", content: @summarize_prompt},
        %{role: "user", content: prompt}
      ],
      stream: false
    }

    case Req.post("#{base_url}/api/chat", json: body, receive_timeout: @timeout_ms) do
      {:ok, %{status: 200, body: %{"message" => %{"content" => text}}}} ->
        trimmed = String.trim(text)
        if trimmed == "", do: {:error, :empty_response}, else: {:ok, trimmed}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[Ollama] HTTP #{status}: #{inspect(body)}")
        {:error, :http_error}

      {:error, reason} ->
        Logger.warning("[Ollama] Request failed: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("[Ollama] Exception: #{inspect(e)}")
      {:error, :exception}
  end

  @doc "Generate a heuristic label from a batch of tool call events (no LLM)."
  def heuristic_label(events) when is_list(events) do
    case events do
      [single] ->
        single_event_label(single)

      multiple ->
        tools = Enum.map(multiple, & &1.tool)

        if Enum.count(Enum.uniq(tools)) == 1 do
          tool = hd(tools)
          group_label(tool, multiple)
        else
          # Mixed tools — use first event's label
          single_event_label(hd(multiple))
        end
    end
  end

  def heuristic_label([]), do: "Processing..."

  @doc "Format events into a prompt string for the LLM."
  def format_events_for_prompt(events) do
    events
    |> Enum.map(fn event ->
      tool = Map.get(event, :tool, "unknown")
      desc = Map.get(event, :description)
      file = Map.get(event, :file)
      pattern = Map.get(event, :pattern)

      parts = [tool]
      parts = if desc && desc != "", do: parts ++ [": #{desc}"], else: parts
      parts = if file, do: parts ++ [" on #{Path.basename(file)}"], else: parts
      parts = if pattern, do: parts ++ [" for #{pattern}"], else: parts
      Enum.join(parts)
    end)
    |> Enum.join("\n")
  end

  # --- Private ---

  defp find_preferred_model(available_names) do
    found =
      Enum.find(@model_preference, fn preferred ->
        Enum.any?(available_names, &String.starts_with?(&1, preferred))
      end)

    if found, do: {:ok, found}, else: :unavailable
  end

  defp single_event_label(event) do
    tool = Map.get(event, :tool, "unknown")
    desc = Map.get(event, :description)
    file = Map.get(event, :file)
    pattern = Map.get(event, :pattern)

    cond do
      is_binary(desc) and desc != "" -> desc
      tool in ["Read", "Glob", "Grep"] and is_binary(file) -> "Reading #{Path.basename(file)}"
      tool == "Glob" and is_binary(pattern) -> "Searching for #{pattern}"
      tool == "Grep" and is_binary(pattern) -> "Searching for #{pattern}"
      true -> tool
    end
  end

  defp group_label("Read", events) do
    count = length(events)
    dirs = events |> Enum.map(&Path.dirname(Map.get(&1, :file, ""))) |> Enum.uniq()

    if length(dirs) == 1 do
      "Reading #{count} files in #{Path.basename(hd(dirs))}"
    else
      "Reading #{count} files"
    end
  end

  defp group_label(tool, events), do: "#{tool} (#{length(events)} calls)"
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/sam/llm/ollama_test.exs --seed 0 -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/sam/llm/ollama.ex test/sam/llm/ollama_test.exs
git commit -m "feat: add Ollama client with heuristic fallback for activity summaries"
```

---

### Task 5: Rewrite Summarizer Backend

**Files:**
- Modify: `lib/sam/session/summarizer.ex`
- Modify: `test/sam/session/summarizer_test.exs`

- [ ] **Step 1: Write tests for new Summarizer behavior**

```elixir
# Add to summarizer_test.exs or rewrite
defmodule Sam.Session.SummarizerTest do
  use ExUnit.Case, async: false

  alias Sam.Session.Summarizer

  setup do
    session_id = "test-summarizer-#{System.unique_integer([:positive])}"
    {:ok, session_id: session_id}
  end

  test "summarizer broadcasts heuristic summary when Ollama unavailable", %{session_id: session_id} do
    Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

    pid = start_supervised!({Summarizer, %{session_id: session_id, debounce_ms: 50}})

    event = %{
      type: :tool_call,
      tool: "Bash",
      description: "Check project status",
      file: nil,
      session_id: session_id,
      timestamp: DateTime.utc_now()
    }

    Phoenix.PubSub.broadcast(Sam.PubSub, "session:#{session_id}", {:parser_event, session_id, event})

    assert_receive {:summary, ^session_id, %{text: text, tool_count: 1}}, 2_000
    assert text == "Check project status"
  end

  test "summarizer batches multiple events", %{session_id: session_id} do
    Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

    pid = start_supervised!({Summarizer, %{session_id: session_id, debounce_ms: 100}})

    for file <- ["/lib/a.ex", "/lib/b.ex", "/lib/c.ex"] do
      event = %{
        type: :tool_call,
        tool: "Read",
        file: file,
        description: nil,
        session_id: session_id,
        timestamp: DateTime.utc_now()
      }
      Phoenix.PubSub.broadcast(Sam.PubSub, "session:#{session_id}", {:parser_event, session_id, event})
    end

    assert_receive {:summary, ^session_id, %{text: text, tool_count: 3}}, 2_000
    assert text =~ "Reading 3 files"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/sam/session/summarizer_test.exs --seed 0 -v`
Expected: FAIL — summary payload format doesn't match (old format has `:summary` key not `:text`)

- [ ] **Step 3: Rewrite Summarizer**

Replace `lib/sam/session/summarizer.ex` with:

```elixir
defmodule Sam.Session.Summarizer do
  use GenServer
  require Logger

  @default_debounce_ms 5_000
  @decision_point_types [:tool_call, :pre_tool_call, :input_needed, :agent_spawn, :activity]
  @health_check_interval_ms 60_000

  defstruct [:session_id, :debounce_ms, :timer_ref, :ollama_model, buffer: []]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    session_id = Map.fetch!(opts, :session_id)
    Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

    # Check Ollama availability on startup
    ollama_model = detect_ollama()

    # Schedule periodic recheck
    Process.send_after(self(), :health_check, @health_check_interval_ms)

    {:ok,
     %__MODULE__{
       session_id: session_id,
       debounce_ms: Map.get(opts, :debounce_ms, @default_debounce_ms),
       ollama_model: ollama_model
     }}
  end

  # Receive parser events via PubSub
  @impl true
  def handle_info({:parser_event, _session_id, %{type: type} = event}, state)
      when type in @decision_point_types do
    state = %{state | buffer: state.buffer ++ [event]}
    state = schedule_summary(state)
    {:noreply, state}
  end

  def handle_info({:parser_event, _, _}, state), do: {:noreply, state}

  def handle_info(:summarize, state) do
    state = do_summarize(state)
    {:noreply, %{state | timer_ref: nil}}
  end

  def handle_info(:health_check, state) do
    ollama_model = detect_ollama()
    Process.send_after(self(), :health_check, @health_check_interval_ms)
    {:noreply, %{state | ollama_model: ollama_model}}
  end

  # Ignore other PubSub messages
  def handle_info({:pty_output, _, _}, state), do: {:noreply, state}
  def handle_info({:pty_exit, _, _}, state), do: {:noreply, state}
  def handle_info({:summary, _, _}, state), do: {:noreply, state}

  # --- Private ---

  defp schedule_summary(state) do
    state = cancel_timer(state)
    ref = Process.send_after(self(), :summarize, state.debounce_ms)
    %{state | timer_ref: ref}
  end

  defp do_summarize(%{buffer: []} = state), do: state

  defp do_summarize(state) do
    tool_events = Enum.filter(state.buffer, &(&1.type in [:tool_call, :pre_tool_call]))
    tool_count = length(tool_events)
    events_for_label = if tool_events == [], do: state.buffer, else: tool_events

    text =
      case state.ollama_model do
        nil ->
          Sam.LLM.Ollama.heuristic_label(events_for_label)

        model ->
          case Sam.LLM.Ollama.summarize(events_for_label, model) do
            {:ok, summary} ->
              summary

            {:error, _reason} ->
              # Fallback to heuristic, trigger faster recheck
              Process.send_after(self(), :health_check, 5_000)
              Sam.LLM.Ollama.heuristic_label(events_for_label)
          end
      end

    Phoenix.PubSub.broadcast(
      Sam.PubSub,
      "session:#{state.session_id}",
      {:summary, state.session_id,
       %{
         text: sanitize_text(text),
         tool_count: max(tool_count, 1),
         timestamp: DateTime.utc_now()
       }}
    )

    %{state | buffer: []}
  end

  defp detect_ollama do
    case Sam.LLM.Ollama.check_availability() do
      {:ok, model} ->
        Logger.info("[Summarizer] Using Ollama model: #{model}")
        model

      :unavailable ->
        Logger.info("[Summarizer] Ollama unavailable, using heuristic fallback")
        nil
    end
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end

  defp sanitize_text(text) when is_binary(text) do
    text
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
    |> String.trim()
    |> case do
      "" -> "Processing..."
      s -> String.slice(s, 0, 120)
    end
  end

  defp sanitize_text(_), do: "Processing..."
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/sam/session/summarizer_test.exs --seed 0 -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/sam/session/summarizer.ex test/sam/session/summarizer_test.exs
git commit -m "feat: rewrite Summarizer to use Ollama with heuristic fallback"
```

---

### Task 6: Wire Summaries into Server Activity Feed

**Files:**
- Modify: `lib/sam/session/server.ex:146-177,219-222,273-281`
- Test: `test/sam/session/server_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
test "server adds summary to activity feed" do
  session_id = "test-summary-feed-#{System.unique_integer([:positive])}"
  opts = %{session_id: session_id}
  pid = start_supervised!({Sam.Session.Server, opts})

  summary = %{text: "Exploring activity feed architecture", tool_count: 3, timestamp: DateTime.utc_now()}
  Phoenix.PubSub.broadcast(Sam.PubSub, "session:#{session_id}", {:summary, session_id, summary})
  :sys.get_state(pid)

  state = Sam.Session.Server.get_state(session_id)
  assert [entry | _] = state.activity
  assert entry.type == :summary
  assert entry.text == "Exploring activity feed architecture"
  assert entry.tool_count == 3
end

test "tool_call events no longer add to activity feed directly" do
  session_id = "test-no-raw-activity-#{System.unique_integer([:positive])}"
  opts = %{session_id: session_id}
  pid = start_supervised!({Sam.Session.Server, opts})

  event = %{type: :tool_call, tool: "Read", description: "/some/file.ex", session_id: session_id, timestamp: DateTime.utc_now()}
  Phoenix.PubSub.broadcast(Sam.PubSub, "session:#{session_id}", {:parser_event, session_id, event})
  :sys.get_state(pid)

  state = Sam.Session.Server.get_state(session_id)
  assert state.activity == []
  # Status should still transition to :working
  assert state.status == :working
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/sam/session/server_test.exs --seed 0 -v`
Expected: FAIL — summary handler is a no-op, tool_call still adds activity

- [ ] **Step 3: Wire summaries, remove raw add_activity**

In `lib/sam/session/server.ex`:

**Replace the summary discard handler (lines 218-222):**

```elixir
@impl true
def handle_info({:summary, _session_id, summary}, state) do
  entry = %{
    type: :summary,
    text: Map.get(summary, :text, "Processing..."),
    tool_count: Map.get(summary, :tool_count, 1),
    timestamp: Map.get(summary, :timestamp, DateTime.utc_now())
  }

  state = %{state | activity: [entry | state.activity] |> Enum.take(50)}
  broadcast_ui_update(state)
  {:noreply, state}
end
```

**In the tool_call/pre_tool_call handler (lines 146-177), remove the `add_activity` call.** Keep status transitions and agent tracking. Remove line 157:

```elixir
# REMOVE: state = add_activity(state, label)
```

The `label` variable and `add_activity/2` function can be removed entirely since they're no longer used (agent description still uses `desc` directly).

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/sam/session/server_test.exs --seed 0 -v`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `mix test --seed 0`
Expected: All pass

- [ ] **Step 6: Commit**

```bash
git add lib/sam/session/server.ex test/sam/session/server_test.exs
git commit -m "feat: wire Summarizer output into activity feed, remove raw tool entries"
```

---

### Task 7: Update LiveView for Summary Entries

**Files:**
- Modify: `lib/sam_web/live/dashboard_live.ex:249-251,485-505`

- [ ] **Step 1: Update activity_msg_class to handle :summary type**

In `lib/sam_web/live/dashboard_live.ex`, update the `activity_msg_class/1` function:

```elixir
defp activity_msg_class(%{type: :system}), do: "system"
defp activity_msg_class(%{type: :agent_event}), do: "agent-event"
defp activity_msg_class(%{type: :summary}), do: "summary"
defp activity_msg_class(_), do: ""
```

- [ ] **Step 2: Update activity feed template to show tool count badge**

In the activity feed section of the template (around line 495-501), update the item rendering:

```heex
<div
  :for={item <- Enum.take(Map.get(state, :activity, []), 50)}
  class="activity-item"
>
  <span class="time">{format_time(item.timestamp)}</span>
  <span class={"msg #{activity_msg_class(item)}"}>{sanitize_text(item.text)}</span>
  <%= if Map.get(item, :tool_count, 0) > 1 do %>
    <span class="tool-count">{item.tool_count}</span>
  <% end %>
</div>
```

- [ ] **Step 3: Add CSS for summary styling and tool count badge**

In `assets/css/app.css`, add after the existing activity-item styles:

```css
.activity-item .msg.summary {
  color: var(--on-surface);
}

.activity-item .tool-count {
  color: var(--primary);
  opacity: 0.5;
  font-size: 0.65rem;
  font-family: var(--font-mono);
  background: rgba(175, 201, 234, 0.1);
  padding: 1px 5px;
  border-radius: 3px;
  flex-shrink: 0;
}
```

- [ ] **Step 4: Run precommit**

Run: `mix precommit`
Expected: PASS (compile, format, test)

- [ ] **Step 5: Commit**

```bash
git add lib/sam_web/live/dashboard_live.ex assets/css/app.css
git commit -m "feat: update dashboard to display summary entries with tool count badges"
```

---

### Task 8: Store Summarization Mode in Settings

**Files:**
- Modify: `lib/sam/settings.ex`
- Modify: `lib/sam_web/live/dashboard_live.ex` (footer indicator)

- [ ] **Step 1: Add summarization mode to Settings on app startup**

The Ollama detection happens in each Summarizer instance already. For the UI indicator, we store the detected mode globally. In `lib/sam/session/summarizer.ex`, update `detect_ollama/0` to also persist to Settings:

```elixir
defp detect_ollama do
  case Sam.LLM.Ollama.check_availability() do
    {:ok, model} ->
      Logger.info("[Summarizer] Using Ollama model: #{model}")
      Sam.Settings.put(:summarizer_mode, {:ollama, model})
      model

    :unavailable ->
      Logger.info("[Summarizer] Ollama unavailable, using heuristic fallback")
      Sam.Settings.put(:summarizer_mode, :heuristic)
      nil
  end
end
```

- [ ] **Step 2: Show active backend in dashboard footer**

In `lib/sam_web/live/dashboard_live.ex`, update the footer:

```heex
<footer class="sam-footer">
  <span>
    <span class="sam-footer-dot" style="background: var(--phosphor-green);"></span>
    {map_size(@sessions)} SESSIONS &bull; THEME: COMMAND
  </span>
  <span style="opacity: 0.5; font-size: 0.7rem;">
    FEED: {summarizer_mode_label()}
  </span>
</footer>
```

Add helper:

```elixir
defp summarizer_mode_label do
  case Sam.Settings.get(:summarizer_mode, :heuristic) do
    {:ollama, model} -> "OLLAMA (#{model})"
    :heuristic -> "HEURISTIC"
    _ -> "HEURISTIC"
  end
end
```

- [ ] **Step 3: Run precommit**

Run: `mix precommit`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add lib/sam/session/summarizer.ex lib/sam_web/live/dashboard_live.ex
git commit -m "feat: show summarization backend indicator in dashboard footer"
```

---

### Task 9: Final Integration Verification

- [ ] **Step 1: Run full test suite**

Run: `mix precommit`
Expected: All pass

- [ ] **Step 2: Manual E2E verification**

1. Ensure Ollama is NOT running
2. Start Phoenix: `mix phx.server`
3. Create a session, observe activity feed shows heuristic labels (not raw tool names)
4. Check elapsed time updates every second
5. Check branch shows correctly in status bar
6. Spawn a subagent, verify it has a title in agents panel
7. Take screenshot for proof

- [ ] **Step 3: Optional — test with Ollama**

1. Start Ollama: `ollama serve`
2. Pull model if needed: `ollama pull gemma3:4b`
3. Restart Phoenix (or wait ~60s for health check)
4. Observe footer changes to "OLLAMA (gemma3:4b)"
5. Create session, verify activity feed shows LLM-generated summaries
6. Take screenshot

- [ ] **Step 4: Commit any fixes from manual testing**

```bash
git add -A
git commit -m "fix: integration fixes from manual E2E testing"
```
