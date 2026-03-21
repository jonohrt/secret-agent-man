# Status Indicator E2E Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automated E2E tests that verify all status indicator transitions, plus the `:background` state and subagent tracking.

**Architecture:** Wallaby browser tests drive a real Phoenix server. A mock agent bash script simulates Claude Code by accepting stdin commands and firing hook HTTP requests. Server state machine gains `:background` state and subagent lifecycle tracking.

**Tech Stack:** Elixir, Phoenix LiveView, Wallaby, Chrome, bash mock agent

**Spec:** `docs/superpowers/specs/2026-03-20-status-indicators-e2e-design.md`

---

### Task 1: Test Infrastructure

**Files:**
- Modify: `config/test.exs`
- Modify: `lib/sam/session/pty.ex:47-54`
- Create: `test/support/mock_agent.sh`
- Create: `lib/sam/agents/mock.ex`
- Modify: `lib/sam_web/live/dashboard_live.ex:154` (agent_adapter)
- Modify: `lib/sam/session/server.ex:15` (struct default)

- [ ] **Step 1: Enable server in test config**

In `config/test.exs`, change `server: false` to `server: true`:

```elixir
config :sam, SamWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "4ywhIKLhiqx9ckMpHQcVbQkSRaik4MENoDTK4TJPYaKsj2pqGMoqpjVAxrHrOMjp",
  server: true
```

- [ ] **Step 2: Fix struct default**

In `lib/sam/session/server.ex`, change the struct default from `:starting` to `:idle`:

```elixir
defstruct [
    :session_id,
    :name,
    :agent_type,
    :branch,
    :workdir,
    :idle_timer,
    :idle_timeout_ms,
    status: :idle,    # was :starting
    activity: [],
    agents: []
  ]
```

- [ ] **Step 3: Add SAM_PORT env var to PTY spawn**

In `lib/sam/session/pty.ex`, update the spawn message to include `SAM_PORT`:

```elixir
port_number =
  Application.get_env(:sam, SamWeb.Endpoint)[:http][:port] || 4000

spawn_msg =
  Jason.encode!(%{
    cmd: "spawn",
    args: command,
    rows: rows,
    cols: cols,
    workdir: workdir,
    env: %{
      "SAM_SESSION_ID" => session_id,
      "SAM_PORT" => to_string(port_number)
    }
  })
```

- [ ] **Step 4: Create mock agent adapter**

Create `lib/sam/agents/mock.ex`:

```elixir
defmodule Sam.Agents.Mock do
  @behaviour Sam.Agents.Behaviour

  @impl true
  def spawn_command(_workdir, _prompt) do
    [Path.join(:code.priv_dir(:sam), "test/mock_agent.sh")]
  end

  @impl true
  def detect_running?, do: false

  @impl true
  def parse_tier, do: :hooks
end
```

- [ ] **Step 5: Register mock adapter in dashboard**

In `lib/sam_web/live/dashboard_live.ex`, add after the existing adapters:

```elixir
defp agent_adapter(:mock), do: Sam.Agents.Mock
```

- [ ] **Step 6: Create mock agent script**

Create `test/support/mock_agent.sh`:

```bash
#!/bin/bash
# Mock agent for E2E tests — simulates Claude Code hook behavior
# Reads commands from stdin, fires hooks to SAM

PORT="${SAM_PORT:-4000}"
SID="${SAM_SESSION_ID:-unknown}"
BASE="http://localhost:${PORT}/api/hooks"

while IFS= read -r line; do
  CMD=$(echo "$line" | awk '{print $1}')
  ARG1=$(echo "$line" | awk '{print $2}')
  ARG2=$(echo "$line" | cut -d' ' -f3-)

  case "$CMD" in
    PRE_TOOL)
      curl -s -X POST "$BASE" \
        -H 'Content-Type: application/json' \
        -d "$(jq -n --arg e "pre_tool_call" --arg s "$SID" --arg t "$ARG1" --arg d "$ARG2" \
          '{event: $e, session_id: $s, tool: $t, description: $d}')" \
        > /dev/null 2>&1
      ;;
    POST_TOOL)
      curl -s -X POST "$BASE" \
        -H 'Content-Type: application/json' \
        -d "$(jq -n --arg e "post_tool_call" --arg s "$SID" --arg t "$ARG1" \
          '{event: $e, session_id: $s, tool: $t}')" \
        > /dev/null 2>&1
      ;;
    PERMISSION)
      echo "? Allow $ARG1 $ARG2 [y/N]"
      ;;
    SLEEP)
      sleep "$ARG1"
      ;;
    EXIT)
      exit "${ARG1:-0}"
      ;;
    *)
      # Echo unknown commands as PTY output
      echo "$line"
      ;;
  esac
done
```

- [ ] **Step 7: Make script executable and copy to priv**

```bash
chmod +x test/support/mock_agent.sh
mkdir -p priv/test
cp test/support/mock_agent.sh priv/test/mock_agent.sh
chmod +x priv/test/mock_agent.sh
```

- [ ] **Step 8: Verify infrastructure compiles**

Run: `mix compile --no-color`
Expected: 0 errors

- [ ] **Step 9: Commit**

```bash
git add config/test.exs lib/sam/agents/mock.ex lib/sam/session/pty.ex \
  lib/sam/session/server.ex lib/sam_web/live/dashboard_live.ex \
  test/support/mock_agent.sh priv/test/mock_agent.sh
git commit -m "feat: E2E test infrastructure — mock agent, SAM_PORT, server: true"
```

---

### Task 2: Batch A Tests RED (Core State Machine)

**Files:**
- Create: `test/features/status_indicator_test.exs`

- [ ] **Step 1: Write all 9 Batch A test skeletons**

Create `test/features/status_indicator_test.exs`:

```elixir
defmodule SamWeb.Features.StatusIndicatorTest do
  use SamWeb.FeatureCase, async: false

  @moduletag :e2e

  # Helper to create a mock agent session programmatically
  defp create_mock_session(session_id, name \\ "test") do
    Sam.Session.GroupSupervisor.start_session(%{
      session_id: session_id,
      name: name,
      agent_type: :mock,
      workdir: File.cwd!(),
      command: [Path.join(:code.priv_dir(:sam), "test/mock_agent.sh")]
    })
  end

  # Helper to send a command to the mock agent via the session
  defp send_to_agent(session_id, command) do
    Sam.Session.Server.send_input(session_id, command <> "\n")
  end

  # Helper to get the status badge text from the page
  defp status_badge_text(session) do
    session
    |> find(Query.css(".status-badge", text: nil))
    |> Element.text()
  end

  describe "core status transitions" do
    @tag :e2e
    test "1: fresh session shows IDLE", %{session: session} do
      sid = "test-e2e-#{System.unique_integer([:positive])}"
      {:ok, _} = create_mock_session(sid, "e2e-idle")

      session
      |> visit("/")
      |> assert_has(Query.css(".status-badge", text: "IDLE", count: 1))

      Sam.Session.GroupSupervisor.terminate_session(sid)
    end

    @tag :e2e
    test "2: user sends input → WORKING within 1 second", %{session: session} do
      sid = "test-e2e-#{System.unique_integer([:positive])}"
      {:ok, _} = create_mock_session(sid, "e2e-working")

      session = visit(session, "/")
      assert_has(session, Query.css(".status-badge", text: "IDLE"))

      # Send input (simulates user pressing Enter)
      send_to_agent(sid, "hello")

      # Should show WORKING within 1 second
      assert_has(session, Query.css(".status-badge", text: "WORKING"))

      Sam.Session.GroupSupervisor.terminate_session(sid)
    end

    @tag :e2e
    test "3: PreToolUse hook → stays WORKING", %{session: session} do
      sid = "test-e2e-#{System.unique_integer([:positive])}"
      {:ok, _} = create_mock_session(sid, "e2e-tool")

      session = visit(session, "/")

      send_to_agent(sid, "PRE_TOOL Read /tmp/test.txt")
      assert_has(session, Query.css(".status-badge", text: "WORKING"))

      Sam.Session.GroupSupervisor.terminate_session(sid)
    end

    @tag :e2e
    test "4: PostToolUse + idle timeout → IDLE", %{session: session} do
      sid = "test-e2e-#{System.unique_integer([:positive])}"
      {:ok, _} = create_mock_session(sid, "e2e-idle-after")

      session = visit(session, "/")

      send_to_agent(sid, "PRE_TOOL Read /tmp/test.txt")
      assert_has(session, Query.css(".status-badge", text: "WORKING"))

      send_to_agent(sid, "POST_TOOL Read")

      # Wait for 5s idle timeout + buffer
      assert_has(session, Query.css(".status-badge", text: "IDLE"),
        timeout: 8_000
      )

      Sam.Session.GroupSupervisor.terminate_session(sid)
    end

    @tag :e2e
    test "5: long-running tool stays WORKING throughout", %{session: session} do
      sid = "test-e2e-#{System.unique_integer([:positive])}"
      {:ok, _} = create_mock_session(sid, "e2e-long")

      session = visit(session, "/")

      send_to_agent(sid, "PRE_TOOL Bash sleep 10")

      # Check at multiple points — should stay WORKING
      assert_has(session, Query.css(".status-badge", text: "WORKING"))
      Process.sleep(3_000)
      assert_has(session, Query.css(".status-badge", text: "WORKING"))
      Process.sleep(3_000)
      assert_has(session, Query.css(".status-badge", text: "WORKING"))

      send_to_agent(sid, "POST_TOOL Bash")
      Sam.Session.GroupSupervisor.terminate_session(sid)
    end

    @tag :e2e
    test "6: multiple tools in sequence stays WORKING", %{session: session} do
      sid = "test-e2e-#{System.unique_integer([:positive])}"
      {:ok, _} = create_mock_session(sid, "e2e-multi")

      session = visit(session, "/")

      send_to_agent(sid, "PRE_TOOL Read mix.exs")
      assert_has(session, Query.css(".status-badge", text: "WORKING"))

      send_to_agent(sid, "POST_TOOL Read")
      # Immediately start another tool before idle timeout
      send_to_agent(sid, "PRE_TOOL Edit lib/app.ex")
      assert_has(session, Query.css(".status-badge", text: "WORKING"))

      send_to_agent(sid, "POST_TOOL Edit")
      Sam.Session.GroupSupervisor.terminate_session(sid)
    end

    @tag :e2e
    test "7: permission prompt → NEEDS INPUT", %{session: session} do
      sid = "test-e2e-#{System.unique_integer([:positive])}"
      {:ok, _} = create_mock_session(sid, "e2e-input")

      session = visit(session, "/")

      send_to_agent(sid, "PERMISSION Allow Read access to /etc/passwd")

      assert_has(session, Query.css(".status-badge", text: "NEEDS INPUT"),
        timeout: 5_000
      )

      Sam.Session.GroupSupervisor.terminate_session(sid)
    end

    @tag :e2e
    test "8: exit 0 → DONE", %{session: session} do
      sid = "test-e2e-#{System.unique_integer([:positive])}"
      {:ok, _} = create_mock_session(sid, "e2e-done")

      session = visit(session, "/")

      send_to_agent(sid, "EXIT 0")

      assert_has(session, Query.css(".status-badge", text: "DONE"),
        timeout: 5_000
      )
    end

    @tag :e2e
    test "9: exit non-zero → ERROR", %{session: session} do
      sid = "test-e2e-#{System.unique_integer([:positive])}"
      {:ok, _} = create_mock_session(sid, "e2e-error")

      session = visit(session, "/")

      send_to_agent(sid, "EXIT 1")

      assert_has(session, Query.css(".status-badge", text: "ERROR"),
        timeout: 5_000
      )
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail (RED)**

Run: `mix test test/features/status_indicator_test.exs --include e2e --no-color`
Expected: Multiple failures (CSS selectors may need adjustment, state machine gaps)

- [ ] **Step 3: Commit RED tests**

```bash
git add test/features/status_indicator_test.exs
git commit -m "test: RED — 9 E2E status indicator tests (Batch A)"
```

---

### Task 3: Make Batch A GREEN

**Files:**
- Modify: `lib/sam/session/server.ex`
- Modify: `lib/sam_web/live/dashboard_live.ex` (status badge CSS class/text)

This task is iterative — run tests, fix the first failure, repeat. Key fixes expected:

- [ ] **Step 1: Fix CSS selector for status badge**

The tests use `Query.css(".status-badge", text: "IDLE")`. Check what CSS class the badge actually uses in the template and adjust tests OR template to match. The current template uses class `status-badge` on the badge element — verify and align.

- [ ] **Step 2: Fix `:needs_input` → `:working` on send_input**

In `server.ex` `handle_cast({:send_input, data})`, the condition `state.status == :idle` must also allow `:needs_input`:

```elixir
if state.status in [:idle, :needs_input] and String.contains?(data, ["\n", "\r"]) do
```

- [ ] **Step 3: Protect terminal states**

In `server.ex`, add a guard at the top of each `handle_info` for parser events and `handle_cast` for send_input:

```elixir
# Add to the top of handle_cast({:send_input, data})
if state.status in [:done, :error] do
  {:noreply, state}
else
  # ... existing logic
end
```

Do the same for all `handle_info({:parser_event, ...})` handlers.

- [ ] **Step 4: Run Batch A tests until all GREEN**

Run: `mix test test/features/status_indicator_test.exs --include e2e --no-color`
Expected: 9 tests, 0 failures

Fix any remaining failures iteratively.

- [ ] **Step 5: Run full test suite**

Run: `mix precommit`
Expected: All tests pass (unit + E2E excluded by default)

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: Batch A GREEN — core status transitions verified E2E"
```

---

### Task 4: Batch B Tests RED (Subagent Tracking)

**Files:**
- Modify: `test/features/status_indicator_test.exs`

- [ ] **Step 1: Add tests 10-15 to the test file**

Add a new `describe "subagent tracking"` block with tests 10-15 (Agent spawns, BACKGROUND state, etc.). Follow the same pattern as Batch A — create mock session, send Agent PreToolUse/PostToolUse commands, assert panel content and badge text.

- [ ] **Step 2: Run to verify RED**

Run: `mix test test/features/status_indicator_test.exs --include e2e --no-color`
Expected: Tests 10-15 fail (`:background` state and subagent tracking don't exist)

- [ ] **Step 3: Commit**

```bash
git add test/features/status_indicator_test.exs
git commit -m "test: RED — 6 E2E subagent tracking tests (Batch B)"
```

---

### Task 5: Implement Subagent Tracking + `:background`

**Files:**
- Modify: `lib/sam/session/server.ex`
- Modify: `lib/sam_web/live/dashboard_live.ex`

- [ ] **Step 1: Add subagent tracking to Server**

In `handle_info({:parser_event, _, %{type: :pre_tool_call} = event})`, when `event.tool == "Agent"`, add an entry to `state.agents`:

```elixir
agent_entry = %{
  id: System.unique_integer([:positive]),
  description: Map.get(event, :description, "subagent"),
  status: :working,
  started_at: DateTime.utc_now()
}
state = %{state | agents: [agent_entry | state.agents]}
```

In `handle_info({:parser_event, _, %{type: :post_tool_call} = event})`, when `event.tool == "Agent"`, mark the most recent `:working` agent as `:done`.

- [ ] **Step 2: Add `:background` transition to idle_timeout**

In `handle_info(:idle_timeout, state)`, check for active subagents:

```elixir
active_agents = Enum.count(state.agents, & &1.status == :working)

if active_agents > 0 do
  state = %{state | status: :background, idle_timer: nil}
else
  state = %{state | status: :idle, idle_timer: nil}
end
```

- [ ] **Step 3: Transition `:background` → `:idle` when last agent completes**

After marking an agent as `:done` in the post_tool_call handler, check if any agents are still working. If none and status is `:background`, transition to `:idle`.

- [ ] **Step 4: Allow `:background` → `:working` on send_input**

Update the `send_input` guard to include `:background`:

```elixir
if state.status in [:idle, :needs_input, :background] and String.contains?(data, ["\n", "\r"]) do
```

- [ ] **Step 5: Update dashboard template for dynamic agents panel**

Replace the hardcoded agents panel with dynamic rendering from `state.agents`:

```heex
<div class="sam-panel-header">
  <span>AGENTS</span>
  <span style="opacity: 0.5;">
    {active_agent_count(state)} ACTIVE
  </span>
</div>
<div class="sam-panel-body">
  <%!-- Main agent row --%>
  <div class="agent-row selected">
    ...existing main agent row...
  </div>
  <%!-- Subagent rows --%>
  <div :for={agent <- Map.get(state, :agents, [])} class="agent-row">
    <div class="agent-row-top">
      <span class={"status-dot #{agent_status_class(agent.status)}"}></span>
      <span class="agent-name">{agent.description}</span>
      <span class={"agent-status #{agent_status_class(agent.status)}"}>
        {agent.status |> to_string() |> String.upcase()}
      </span>
    </div>
  </div>
</div>
```

- [ ] **Step 6: Run Batch B tests until GREEN**

Run: `mix test test/features/status_indicator_test.exs --include e2e --no-color`
Expected: All 15 tests pass

- [ ] **Step 7: Run full suite**

Run: `mix precommit`
Expected: All tests pass

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: subagent tracking + :background state — Batch B GREEN"
```

---

### Task 6: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update status state machine documentation**

Replace the old state machine in CLAUDE.md with:

```
:idle -> :working <-> :idle
           |
       :background (subagents running)
           |
         :idle (last agent done)

:idle/:working -> :needs_input -> :working (user responds)
:any -> :done (exit 0) | :error (exit non-zero)
```

- [ ] **Step 2: Add E2E test command**

Add to the Test Commands section:

```bash
mix test --include e2e          # Run E2E browser tests (requires chromedriver)
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update status state machine and add E2E test command"
```
