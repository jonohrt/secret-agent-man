# Hook Events Activity Feed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace garbage LLM-summarized terminal output with structured activity lines from Claude Code hook events.

**Architecture:** SAM exposes an HTTP endpoint that receives Claude Code hook events (PreToolUse, PostToolUse, Stop, etc.). The Summarizer is rewritten to format these structured events into clean activity lines. Claude Code sessions are spawned with a settings file that configures hooks to POST to SAM.

**Tech Stack:** Phoenix HTTP endpoint, Claude Code hooks (command type with curl), existing PubSub infrastructure.

---

### Task 1: HTTP Endpoint to Receive Hook Events

**Files:**
- Create: `lib/sam_web/controllers/hook_controller.ex`
- Modify: `lib/sam_web/router.ex`
- Create: `test/sam_web/controllers/hook_controller_test.exs`

- [ ] **Step 1: Write failing test for hook endpoint**

```elixir
# test/sam_web/controllers/hook_controller_test.exs
defmodule SamWeb.HookControllerTest do
  use SamWeb.ConnCase, async: true

  describe "POST /api/hooks/:session_id" do
    test "accepts PreToolUse event and returns 200", %{conn: conn} do
      payload = %{
        "hook_event_name" => "PreToolUse",
        "session_id" => "test-session",
        "tool_name" => "Edit",
        "tool_input" => %{"file_path" => "/src/app.ex"}
      }

      conn = post(conn, "/api/hooks/test-session", payload)
      assert json_response(conn, 200) == %{"ok" => true}
    end

    test "accepts PostToolUse event and returns 200", %{conn: conn} do
      payload = %{
        "hook_event_name" => "PostToolUse",
        "session_id" => "test-session",
        "tool_name" => "Bash",
        "tool_input" => %{"command" => "mix test"},
        "tool_result" => %{"output" => "3 tests, 0 failures"}
      }

      conn = post(conn, "/api/hooks/test-session", payload)
      assert json_response(conn, 200) == %{"ok" => true}
    end

    test "rejects unknown event with 422", %{conn: conn} do
      conn = post(conn, "/api/hooks/test-session", %{"hook_event_name" => "Unknown"})
      assert json_response(conn, 422)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/sam_web/controllers/hook_controller_test.exs`
Expected: FAIL — no route matches

- [ ] **Step 3: Add route and controller**

```elixir
# In router.ex, add inside a pipeline/scope:
scope "/api", SamWeb do
  pipe_through :api
  post "/hooks/:session_id", HookController, :create
end
```

```elixir
# lib/sam_web/controllers/hook_controller.ex
defmodule SamWeb.HookController do
  use SamWeb, :controller

  @known_events ~w(PreToolUse PostToolUse Stop SessionStart SessionEnd Notification)

  def create(conn, %{"session_id" => session_id, "hook_event_name" => event_name} = params)
      when event_name in @known_events do
    Sam.Session.Server.push_hook_event(session_id, params)
    json(conn, %{ok: true})
  end

  def create(conn, _params) do
    conn
    |> put_status(422)
    |> json(%{error: "unknown or missing event"})
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/sam_web/controllers/hook_controller_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/sam_web/controllers/hook_controller.ex lib/sam_web/router.ex test/sam_web/controllers/hook_controller_test.exs
git commit -m "feat: add HTTP endpoint for Claude Code hook events"
```

---

### Task 2: Rewrite Summarizer to Format Structured Events

**Files:**
- Modify: `lib/sam/session/summarizer.ex`
- Modify: `test/sam/session/summarizer_test.exs`

- [ ] **Step 1: Write failing tests for structured event formatting**

```elixir
# Replace the existing summarizer test with structured event tests
defmodule Sam.Session.SummarizerTest do
  use ExUnit.Case, async: true

  alias Sam.Session.Summarizer

  describe "format_event/1" do
    test "formats PreToolUse Edit event" do
      event = %{
        "hook_event_name" => "PreToolUse",
        "tool_name" => "Edit",
        "tool_input" => %{"file_path" => "/src/server.ex"}
      }
      assert Summarizer.format_event(event) == "Editing server.ex"
    end

    test "formats PreToolUse Read event" do
      event = %{
        "hook_event_name" => "PreToolUse",
        "tool_name" => "Read",
        "tool_input" => %{"file_path" => "/src/parser.ex"}
      }
      assert Summarizer.format_event(event) == "Reading parser.ex"
    end

    test "formats PreToolUse Bash event" do
      event = %{
        "hook_event_name" => "PreToolUse",
        "tool_name" => "Bash",
        "tool_input" => %{"command" => "mix test --failed"}
      }
      assert Summarizer.format_event(event) == "Running `mix test --failed`"
    end

    test "truncates long Bash commands" do
      event = %{
        "hook_event_name" => "PreToolUse",
        "tool_name" => "Bash",
        "tool_input" => %{"command" => String.duplicate("a", 200)}
      }
      result = Summarizer.format_event(event)
      assert String.length(result) <= 80
      assert String.ends_with?(result, "...`")
    end

    test "formats PreToolUse Write event" do
      event = %{
        "hook_event_name" => "PreToolUse",
        "tool_name" => "Write",
        "tool_input" => %{"file_path" => "/src/new_file.ex"}
      }
      assert Summarizer.format_event(event) == "Creating new_file.ex"
    end

    test "formats PreToolUse Grep event" do
      event = %{
        "hook_event_name" => "PreToolUse",
        "tool_name" => "Grep",
        "tool_input" => %{"pattern" => "def handle_info"}
      }
      assert Summarizer.format_event(event) == "Searching for `def handle_info`"
    end

    test "formats PreToolUse Glob event" do
      event = %{
        "hook_event_name" => "PreToolUse",
        "tool_name" => "Glob",
        "tool_input" => %{"pattern" => "**/*_test.exs"}
      }
      assert Summarizer.format_event(event) == "Finding files matching `**/*_test.exs`"
    end

    test "formats Stop event" do
      event = %{"hook_event_name" => "Stop"}
      assert Summarizer.format_event(event) == "Finished responding"
    end

    test "formats unknown tool with fallback" do
      event = %{
        "hook_event_name" => "PreToolUse",
        "tool_name" => "SomeNewTool",
        "tool_input" => %{}
      }
      assert Summarizer.format_event(event) == "Using SomeNewTool"
    end

    test "returns nil for PostToolUse (no duplicate noise)" do
      event = %{
        "hook_event_name" => "PostToolUse",
        "tool_name" => "Edit",
        "tool_input" => %{"file_path" => "/src/server.ex"}
      }
      assert Summarizer.format_event(event) == nil
    end
  end

  describe "GenServer event flow" do
    test "hook events produce structured activity lines" do
      session_id = "test-summarizer-hooks-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

      {:ok, _pid} = Summarizer.start_link(%{session_id: session_id, debounce_ms: 100})

      # Simulate hook events arriving via PubSub
      Phoenix.PubSub.broadcast(Sam.PubSub, "session:#{session_id}",
        {:hook_event, session_id, %{
          "hook_event_name" => "PreToolUse",
          "tool_name" => "Edit",
          "tool_input" => %{"file_path" => "/src/server.ex"}
        }})

      Phoenix.PubSub.broadcast(Sam.PubSub, "session:#{session_id}",
        {:hook_event, session_id, %{
          "hook_event_name" => "PreToolUse",
          "tool_name" => "Bash",
          "tool_input" => %{"command" => "mix test"}
        }})

      assert_receive {:summary, ^session_id, %{summary: summary}}, 500
      assert summary =~ "Editing server.ex"
      assert summary =~ "Running `mix test`"
    end

    test "ignores raw PTY activity events" do
      session_id = "test-summarizer-ignore-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

      {:ok, _pid} = Summarizer.start_link(%{session_id: session_id, debounce_ms: 100})

      # Raw PTY activity should be ignored
      Phoenix.PubSub.broadcast(Sam.PubSub, "session:#{session_id}",
        {:parser_event, session_id, %{type: :activity, lines: ["garbage terminal output"]}})

      refute_receive {:summary, ^session_id, _}, 300
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/sam/session/summarizer_test.exs`
Expected: FAIL — `format_event/1` undefined, GenServer doesn't handle hook_event

- [ ] **Step 3: Rewrite Summarizer**

Replace `lib/sam/session/summarizer.ex` with:
- `format_event/1` — pure function, pattern matches on hook event name + tool name → returns human-readable string or nil
- GenServer listens for `{:hook_event, session_id, event}` instead of `{:parser_event, ...}`
- Buffers formatted lines, debounces, broadcasts as `{:summary, ...}`
- Drops raw `:activity` events from Parser (no more terminal garbage)
- No LLM dependency

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/sam/session/summarizer_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/sam/session/summarizer.ex test/sam/session/summarizer_test.exs
git commit -m "feat: rewrite summarizer to format structured hook events"
```

---

### Task 3: Wire Hook Events Through Server to Summarizer

**Files:**
- Modify: `lib/sam/session/server.ex`
- Modify: `test/sam/session/server_test.exs`

- [ ] **Step 1: Write failing test for hook event forwarding**

```elixir
# Add to server_test.exs
describe "hook event forwarding" do
  test "broadcasts hook events to session PubSub" do
    session_id = "test-hook-fwd-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")
    Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

    {:ok, _} = Sam.Session.GroupSupervisor.start_session(%{
      session_id: session_id,
      command: ["/bin/bash", "-l"],
      agent_type: :generic,
      name: "Hook Test"
    })

    # Synchronize — wait for session to be registered
    _ = Sam.Session.Server.get_state(session_id)

    # Push a hook event
    Sam.Session.Server.push_hook_event(session_id, %{
      "hook_event_name" => "PreToolUse",
      "tool_name" => "Edit",
      "tool_input" => %{"file_path" => "/src/app.ex"}
    })

    assert_receive {:hook_event, ^session_id, %{"hook_event_name" => "PreToolUse"}}, 1000

    Sam.Session.Server.stop(session_id)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/sam/session/server_test.exs`
Expected: FAIL — Server.push_hook_event doesn't broadcast {:hook_event, ...}

- [ ] **Step 3: Update Server to broadcast hook events directly**

Currently `push_hook_event` routes through Parser's `parse_hook_event`. Change it to broadcast `{:hook_event, session_id, raw_event}` directly on the session PubSub topic so the Summarizer can receive it.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/sam/session/server_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/sam/session/server.ex test/sam/session/server_test.exs
git commit -m "feat: forward hook events on session PubSub for summarizer"
```

---

### Task 4: Configure Claude Code Hooks on Session Spawn

**Files:**
- Modify: `lib/sam/agents/claude_code.ex`
- Create: `test/sam/agents/claude_code_test.exs`

- [ ] **Step 1: Write failing test for hook configuration in spawn command**

```elixir
defmodule Sam.Agents.ClaudeCodeTest do
  use ExUnit.Case, async: true

  alias Sam.Agents.ClaudeCode

  describe "spawn_command/3" do
    test "includes hook flags for PreToolUse and Stop" do
      command = ClaudeCode.spawn_command(nil, nil, "test-session-1")
      command_str = Enum.join(command, " ")

      assert command_str =~ "--hook-after-tool-use"
          or command_str =~ "settings"
      # Verify the command will notify SAM on tool use
    end
  end
end
```

Note: The exact hook configuration approach depends on whether Claude Code supports `--hook` CLI flags or requires a settings file. Two options:
- **Option A**: Write a per-session `.claude/settings.local.json` into the workdir before spawning
- **Option B**: Use environment variables or CLI flags if supported

Research needed: check if Claude Code supports hook configuration via CLI args or only via settings files.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/sam/agents/claude_code_test.exs`
Expected: FAIL

- [ ] **Step 3: Implement hook configuration**

Update `spawn_command` to accept `session_id` and configure hooks to POST to `http://localhost:4000/api/hooks/:session_id`. Either:
- Write a temp settings file with hook config, or
- Pass hook config via CLI flag

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/sam/agents/claude_code_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/sam/agents/claude_code.ex test/sam/agents/claude_code_test.exs
git commit -m "feat: configure Claude Code hooks to POST events to SAM"
```

---

### Task 5: Remove LLM Client Dependency from Summarizer

**Files:**
- Modify: `lib/sam/llm/client.ex` (keep for future use but remove from summarizer path)
- Verify: No other code calls `Sam.LLM.Client.summarize/1` from the activity path

- [ ] **Step 1: Verify no summarizer references to LLM Client**

Run: `mix test`
Expected: All tests pass, confirming the LLM client is no longer in the summarizer path

- [ ] **Step 2: Run full precommit**

Run: `mix precommit`
Expected: PASS — compile clean, format clean, all tests pass

- [ ] **Step 3: Commit**

```bash
git commit -m "chore: remove LLM dependency from activity feed path"
```

---

### Task 6: Integration Test — End to End

**Files:**
- Create: `test/sam/integration/hook_activity_test.exs`

- [ ] **Step 1: Write integration test**

```elixir
defmodule Sam.Integration.HookActivityTest do
  use SamWeb.ConnCase, async: false

  test "hook POST → summarizer → activity feed", %{conn: conn} do
    session_id = "test-integration-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")

    # Start a session (use bash, not claude, for test)
    {:ok, _} = Sam.Session.GroupSupervisor.start_session(%{
      session_id: session_id,
      command: ["/bin/bash"],
      agent_type: :generic,
      name: "Integration Test"
    })

    # Simulate Claude Code posting a hook event
    post(conn, "/api/hooks/#{session_id}", %{
      "hook_event_name" => "PreToolUse",
      "tool_name" => "Edit",
      "tool_input" => %{"file_path" => "/src/server.ex"}
    })

    # Should receive a structured summary in the UI update
    assert_receive {:session_update, ^session_id, state}, 2000
    assert Enum.any?(state.activity, fn item ->
      item.text =~ "Editing server.ex"
    end)

    Sam.Session.Server.stop(session_id)
  end
end
```

- [ ] **Step 2: Run integration test**

Run: `mix test test/sam/integration/hook_activity_test.exs`
Expected: PASS

- [ ] **Step 3: Run full precommit**

Run: `mix precommit`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add test/sam/integration/hook_activity_test.exs
git commit -m "test: add end-to-end hook activity integration test"
```
