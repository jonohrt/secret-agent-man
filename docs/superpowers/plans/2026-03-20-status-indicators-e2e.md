# Status Indicators End-to-End Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Get status indicator dots working end-to-end — from Claude Code JSONL transcript writes through to visible status dot color changes in the browser.

**Architecture:** TranscriptWatcher polls Claude Code's JSONL file, emits parser events over PubSub. Server state machine receives events, transitions status, broadcasts to LiveView. The plumbing exists but has never been verified live. This plan is diagnostic-first: investigate what's actually broken, fix it with TDD, then verify E2E.

**Tech Stack:** Elixir, Phoenix LiveView, PubSub, GenServer, Wallaby (new), xterm.js

**Spec:** `docs/superpowers/specs/2026-03-20-status-indicators-e2e-design.md`
**Beads Epic:** `secret-agent-man-k1m`

---

## File Map

| File | Role | Action |
|------|------|--------|
| `lib/sam/session/transcript_watcher.ex` | JSONL file discovery + parsing | Modify (fix based on diagnosis) |
| `test/sam/session/transcript_watcher_test.exs` | TranscriptWatcher unit tests | Modify (refactor + add tests) |
| `lib/sam_web/live/dashboard_live.ex:66-67` | Session creation — workdir handling | Possibly modify |
| `config/test.exs` | Test config | Modify (Wallaby config) |
| `mix.exs:41-64` | Dependencies | Modify (add wallaby) |
| `test/support/feature_case.ex` | Wallaby test case module | Create |
| `test/sam_web/live/status_indicator_test.exs` | E2E browser test | Create |

---

### Task 1: Diagnose JSONL file discovery failure (`k1m.1` — diagnostic)

This task does NOT write code. It uses Tidewave to inspect live state and determine the actual root cause.

**Prereqs:** Phoenix server running (`mix phx.server`)

- [ ] **Step 1: Start Phoenix server**

Run: `mix phx.server`

- [ ] **Step 2: Create a session with explicit workdir**

In the browser at `http://localhost:4000`, click "+ DEPLOY AGENT", fill in:
- SESSION_IDENTITY: "diag-test"
- DEPLOYMENT_VECTOR: `/Users/johrt/Code/secret-agent-man`
- Leave prompt empty

- [ ] **Step 3: Inspect TranscriptWatcher state via Tidewave**

Use `mcp__tidewave__project_eval` to find and inspect the watcher:

```elixir
# Find the TranscriptWatcher process for this session
children = DynamicSupervisor.which_children(Sam.SessionSupervisor)
# Get the GroupSupervisor pid
# Find all TranscriptWatcher states (handles 0 or multiple sessions)
Enum.flat_map(children, fn {_, pid, _, _} ->
  Supervisor.which_children(pid)
  |> Enum.filter(fn {id, _, _, _} -> id == Sam.Session.TranscriptWatcher end)
  |> Enum.map(fn {_, watcher_pid, _, _} -> :sys.get_state(watcher_pid) end)
end)
```

Record the values of: `workdir`, `path`, `offset`.

- [ ] **Step 4: Verify path encoding**

Use `mcp__tidewave__project_eval`:

```elixir
# What TranscriptWatcher computes
workdir = "/Users/johrt/Code/secret-agent-man"
encoded = String.replace(workdir, "/", "-")
computed = Path.join(System.user_home!() <> "/.claude/projects", encoded)

# What actually exists
{:ok, dirs} = File.ls(System.user_home!() <> "/.claude/projects")
matching = Enum.filter(dirs, &String.contains?(&1, "secret-agent-man"))

{computed, matching}
```

- [ ] **Step 5: Check if JSONL files exist in that directory**

```elixir
dir = Path.join(System.user_home!(), ".claude/projects/-Users-johrt-Code-secret-agent-man")
case File.ls(dir) do
  {:ok, files} -> Enum.filter(files, &String.ends_with?(&1, ".jsonl"))
  error -> error
end
```

- [ ] **Step 6: Document findings**

Append findings under a `## Diagnosis Findings` heading at the bottom of this plan file. Record: which failure mode was confirmed, the actual values observed, and which fix path (A/B/C) to follow. Then proceed to Task 2.

If none of the three suspected failure modes match, investigate further with Tidewave before proceeding. Do not guess.

---

### Task 2: Refactor TranscriptWatcher tests to remove Process.sleep (`k1m.1`)

**Files:**
- Modify: `test/sam/session/transcript_watcher_test.exs`

**Beads:** `secret-agent-man-k1m.1`

The existing tests use `Process.sleep(100)` to wait for the watcher to initialize. Replace with `:sys.get_state/1` which blocks until the GenServer has processed all pending messages.

- [ ] **Step 1: Replace Process.sleep with :sys.get_state**

In `test/sam/session/transcript_watcher_test.exs`, replace each `Process.sleep(100)` with `_ = :sys.get_state(pid)`:

```elixir
# BEFORE (line 20):
Process.sleep(100)

# AFTER:
_ = :sys.get_state(pid)
```

Apply the same change at lines 53 and 85.

- [ ] **Step 2: Run tests to verify they still pass**

Run: `mix test test/sam/session/transcript_watcher_test.exs -v`
Expected: All 3 tests pass

- [ ] **Step 3: Commit**

```bash
git add test/sam/session/transcript_watcher_test.exs
git commit -m "test: replace Process.sleep with :sys.get_state in TranscriptWatcher tests"
```

---

### Task 3: Fix JSONL file discovery based on diagnosis (`k1m.1`)

**Files:**
- Modify: `lib/sam/session/transcript_watcher.ex` (specific changes depend on Task 1 findings)
- Modify: `test/sam/session/transcript_watcher_test.exs`
- Possibly modify: `lib/sam_web/live/dashboard_live.ex:66-67`

**Beads:** `secret-agent-man-k1m.1`

This task depends on Task 1 findings. Below are the three likely fix paths — execute the one that matches.

#### Path A: Workdir is nil (form doesn't send it)

- [ ] **Step A1: Write failing test — dashboard sends cwd when workdir blank**

The fix for nil workdir is in the dashboard layer (always send a workdir), not in TranscriptWatcher. Add a LiveView test to `test/sam_web/live/dashboard_live_test.exs`:

```elixir
test "create_session with blank workdir defaults to File.cwd!()", %{conn: conn} do
  {:ok, view, _html} = live(conn, "/")

  # Submit form with blank workdir
  view
  |> element("form[phx-submit=create_session]")
  |> render_submit(%{"name" => "test-nil-wd", "agent_type" => "claude_code", "workdir" => "", "prompt" => ""})

  # Verify a session was created — check via Server state
  sessions = Sam.Session.Server.list_sessions()
  assert length(sessions) > 0
end
```

- [ ] **Step A2: Fix dashboard to always send workdir**

In `lib/sam_web/live/dashboard_live.ex`, change line 67:

```elixir
# BEFORE:
workdir = if workdir == "", do: nil, else: workdir

# AFTER:
workdir = if workdir == "" or is_nil(workdir), do: File.cwd!(), else: workdir
```

- [ ] **Step A3: Run tests**

Run: `mix test -v`
Expected: All tests pass including the new dashboard test

#### Path B: Path encoding mismatch

- [ ] **Step B1: Write failing test with the actual encoding**

```elixir
test "project_dir encodes path matching Claude Code format" do
  # Use the actual directory name from ~/.claude/projects/
  workdir = "/Users/johrt/Code/secret-agent-man"
  expected = Path.join(System.user_home!() <> "/.claude/projects", "-Users-johrt-Code-secret-agent-man")

  # We need to test project_dir/1 — currently private.
  # Either make it public or test via find_jsonl behavior.
  session_id = "test-tw-#{System.unique_integer([:positive])}"
  {:ok, pid} = GenServer.start_link(Sam.Session.TranscriptWatcher, %{
    session_id: session_id,
    workdir: workdir
  })

  state = :sys.get_state(pid)
  assert state.workdir == workdir
  GenServer.stop(pid)
end
```

- [ ] **Step B2: Fix project_dir/1 encoding**

Adjust `transcript_watcher.ex` `project_dir/1` to match Claude Code's actual encoding scheme discovered in Task 1.

#### Path C: Race condition (picks old file)

- [ ] **Step C1: Add session_start_time to state**

In `transcript_watcher.ex` `init/1`:

```elixir
state = %{
  session_id: session_id,
  workdir: workdir,
  path: test_path,
  offset: if(test_path, do: file_size(test_path), else: 0),
  line_buffer: "",
  started_at: System.os_time(:second)  # NEW
}
```

- [ ] **Step C2: Filter JSONL files by creation time**

In `find_jsonl/1`, change to `find_jsonl/2` accepting started_at, and filter:

```elixir
defp find_jsonl(workdir, started_at) do
  dir = project_dir(workdir)

  case File.ls(dir) do
    {:ok, files} ->
      files
      |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.filter(fn path ->
        case File.stat(path, time: :posix) do
          {:ok, %{mtime: mtime}} -> mtime >= started_at
          _ -> false
        end
      end)
      |> Enum.sort_by(
        fn path ->
          case File.stat(path, time: :posix) do
            {:ok, %{mtime: mtime}} -> mtime
            _ -> 0
          end
        end,
        :desc
      )
      |> List.first()

    _ ->
      nil
  end
end
```

---

#### Common for all paths:

- [ ] **Step 4: Run mix precommit**

Run: `mix precommit`
Expected: compile (0 warnings), format OK, all tests pass

- [ ] **Step 5: Commit the fix**

```bash
git add lib/sam/session/transcript_watcher.ex test/sam/session/transcript_watcher_test.exs
# Add dashboard_live.ex if Path A was used
git commit -m "fix: TranscriptWatcher JSONL file discovery for live sessions"
```

- [ ] **Step 6: Close Beads issue**

```bash
bd close secret-agent-man-k1m.1
```

---

### Task 4: E2E manual verification (`k1m.2`)

**Beads:** `secret-agent-man-k1m.2`

This task verifies the fix works in a real browser with a real Claude Code session.

- [ ] **Step 1: Restart Phoenix server**

Kill any running server and start fresh:
Run: `mix phx.server`

- [ ] **Step 2: Create session with workdir**

In browser at `http://localhost:4000`:
- Click "+ DEPLOY AGENT"
- Name: "verify-status"
- Workdir: `/Users/johrt/Code/secret-agent-man`
- Prompt: "Read the README.md file and summarize it"

- [ ] **Step 3: Verify TranscriptWatcher found the file**

Use `mcp__tidewave__project_eval`:

```elixir
children = DynamicSupervisor.which_children(Sam.SessionSupervisor)
Enum.flat_map(children, fn {_, pid, _, _} ->
  Supervisor.which_children(pid)
  |> Enum.filter(fn {id, _, _, _} -> id == Sam.Session.TranscriptWatcher end)
  |> Enum.map(fn {_, watcher_pid, _, _} -> :sys.get_state(watcher_pid) end)
end)
```

Expected: `path` is non-nil, points to a `.jsonl` file in `~/.claude/projects/-Users-johrt-Code-secret-agent-man/`

- [ ] **Step 4: Screenshot status transitions**

Use `mcp__screenshot-website-fast__take_screenshot` at `http://localhost:4000` to capture:
1. Starting state (pulsing blue dot)
2. Working state (green glowing dot) — while Claude is reading files
3. Idle state (gray dot) — after Claude finishes
4. Done state (blue dot) — after session exits

- [ ] **Step 5: Close Beads issue**

```bash
bd close secret-agent-man-k1m.2
```

---

### Task 5: Set up Wallaby E2E test framework (`k1m.3`)

**Files:**
- Modify: `mix.exs:41-64` (add wallaby dep)
- Modify: `config/test.exs` (enable server, configure wallaby)
- Create: `test/support/feature_case.ex`

**Beads:** `secret-agent-man-k1m.3`

- [ ] **Step 0: Verify ChromeDriver is installed**

Run: `chromedriver --version`
Expected: Something like `ChromeDriver 125.0.6422.60`. If missing, install via `brew install chromedriver`.

- [ ] **Step 1: Add wallaby dependency**

In `mix.exs`, add to deps:

```elixir
{:wallaby, "~> 0.30", only: :test, runtime: false}
```

- [ ] **Step 2: Install deps**

Run: `mix deps.get`

- [ ] **Step 3: Configure test endpoint for Wallaby**

In `config/test.exs`, keep `server: false` (unit tests don't need it). Add Wallaby config below the endpoint config:

```elixir
# Wallaby will start the server itself for E2E tests
config :wallaby,
  otp_app: :sam,
  driver: Wallaby.Chrome,
  screenshot_on_failure: true,
  js_logger: :log
```

**Note:** Wallaby's `Wallaby.Feature` handles starting the endpoint with `server: true` for its own tests. Keeping `server: false` in config avoids slowing down unit tests.

- [ ] **Step 4: Create FeatureCase module**

Create `test/support/feature_case.ex`:

```elixir
defmodule SamWeb.FeatureCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use Wallaby.Feature

      @endpoint SamWeb.Endpoint
      use SamWeb, :verified_routes

      import Wallaby.Query
    end
  end
end
```

- [ ] **Step 5: Add Wallaby to test_helper.exs**

In `test/test_helper.exs`, add before `ExUnit.start()`:

```elixir
{:ok, _} = Application.ensure_all_started(:wallaby)
```

Also add after `ExUnit.start()`:

```elixir
ExUnit.configure(exclude: [:e2e])
```

This excludes `@tag :e2e` tests from normal `mix test` runs. Use `mix test --include e2e` to run them explicitly.

- [ ] **Step 6: Run mix precommit**

Run: `mix precommit`
Expected: compile (0 warnings), format OK, all tests pass (no Wallaby tests yet, just verifying setup)

- [ ] **Step 7: Commit**

```bash
git add mix.exs mix.lock config/test.exs test/support/feature_case.ex test/test_helper.exs
git commit -m "feat: add Wallaby E2E test framework"
```

---

### Task 6: Write status indicator E2E test (`k1m.3`)

**Files:**
- Create: `test/sam_web/live/status_indicator_test.exs`

**Beads:** `secret-agent-man-k1m.3`

This test creates a session via the UI, writes mock JSONL to simulate Claude Code, and verifies status dot transitions in the browser.

- [ ] **Step 1: Write the E2E test**

Create `test/sam_web/live/status_indicator_test.exs`:

```elixir
defmodule SamWeb.Live.StatusIndicatorTest do
  use SamWeb.FeatureCase, async: false

  @tag :e2e
  feature "status dot transitions through working → idle → done", %{session: session} do
    # Set up a temp dir to act as the JSONL target
    tmp_dir = System.tmp_dir!()
    workdir = tmp_dir
    jsonl_dir = Path.join(
      System.user_home!() <> "/.claude/projects",
      String.replace(workdir, "/", "-")
    )
    File.mkdir_p!(jsonl_dir)
    jsonl_path = Path.join(jsonl_dir, "test-#{System.unique_integer([:positive])}.jsonl")
    File.write!(jsonl_path, "")

    # Visit dashboard
    session
    |> visit("/")

    # Create a session with the temp workdir
    session
    |> click(Query.button("+ DEPLOY AGENT"))
    |> fill_in(Query.text_field("name"), with: "e2e-status-test")
    |> fill_in(Query.text_field("workdir"), with: workdir)
    |> click(Query.button("INITIATE OPERATION"))

    # Wait for session to appear in the list
    assert_has(session, Query.css(".status-dot"))

    # Write a tool_call JSONL record to simulate Claude working
    tool_call = Jason.encode!(%{
      "message" => %{
        "role" => "assistant",
        "content" => [%{"type" => "tool_use", "id" => "t1", "name" => "Read", "input" => %{}}]
      }
    })
    File.write!(jsonl_path, tool_call <> "\n", [:append])

    # Status should transition to working (green dot)
    assert_has(session, Query.css(".status-dot.working"), minimum: 1)

    # Write a turn_duration to simulate Claude finishing
    turn_end = Jason.encode!(%{"type" => "system", "subtype" => "turn_duration"})
    File.write!(jsonl_path, turn_end <> "\n", [:append])

    # Wait for idle timeout (5s default + buffer)
    Process.sleep(6_000)

    # Status should transition to idle (gray dot)
    assert_has(session, Query.css(".status-dot.idle"), minimum: 1)

    on_exit(fn -> File.rm(jsonl_path) end)
  end
end
```

- [ ] **Step 2: Run the E2E test**

Run: `mix test test/sam_web/live/status_indicator_test.exs --include e2e -v`
Expected: PASS (may need adjustments to selectors based on actual DOM)

- [ ] **Step 3: Run full test suite**

Run: `mix precommit`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add test/sam_web/live/status_indicator_test.exs
git commit -m "test: add E2E status indicator test with Wallaby"
```

- [ ] **Step 5: Close Beads issue**

```bash
bd close secret-agent-man-k1m.3
```

---

## Notes for the implementer

- **Task 1 is the most important task.** Everything else depends on understanding what's actually broken. Do not skip it or guess.
- **Use Tidewave liberally.** `mcp__tidewave__project_eval` lets you inspect live GenServer state without adding debug code. Use it in Tasks 1, 3, and 4.
- **The TranscriptWatcher `_test_jsonl_path` bypass** is how tests skip file discovery. Real sessions don't have this — they rely on `find_jsonl/1`. This is the code path that's never been exercised live.
- **Process.sleep in Task 6 is acceptable** — it's waiting for a real 5-second idle timeout in an E2E test, not synchronizing GenServer messages. Use `assert_receive` for unit tests, but E2E tests may need real time waits.
- **The `@tag :e2e` tag** lets you exclude slow E2E tests from normal `mix test` runs. Configure in `test/test_helper.exs` with `ExUnit.configure(exclude: [:e2e])` if desired.
- **Wallaby requires Chrome/ChromeDriver** installed. Verify with `chromedriver --version` before running E2E tests.
