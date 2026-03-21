defmodule SamWeb.Features.StatusIndicatorTest do
  use SamWeb.FeatureCase, async: false

  import Wallaby.Query

  @moduletag :e2e

  # Helper to start a mock agent session wired to the test endpoint
  defp start_mock_session do
    sid = "test-e2e-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Sam.Session.GroupSupervisor.terminate_session(sid)
    end)

    {:ok, _} =
      Sam.Session.GroupSupervisor.start_session(%{
        session_id: sid,
        name: sid,
        agent_type: :mock,
        workdir: File.cwd!(),
        command: [Path.join(:code.priv_dir(:sam), "test/mock_agent.sh")]
      })

    # Give the process tree a moment to initialize
    Process.sleep(500)
    sid
  end

  defp status_badge(text) do
    css(".sam-status-badge", text: text)
  end

  # Wallaby's assert_has uses the global max_wait_time (default 3s).
  # For tests that need longer waits, we poll manually.
  defp await_status(session, text, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_status(session, text, deadline)
  end

  defp do_await_status(session, text, deadline) do
    try do
      assert_has(session, status_badge(text))
    rescue
      Wallaby.ExpectationNotMetError ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(250)
          do_await_status(session, text, deadline)
        else
          # Final attempt — let the assertion error propagate
          assert_has(session, status_badge(text))
        end
    end
  end

  # --- Test 1: Fresh session shows IDLE ---

  test "fresh session shows IDLE status", %{session: session} do
    _sid = start_mock_session()

    session
    |> visit("/")
    |> assert_has(status_badge("IDLE"))
  end

  # --- Test 2: User sends input → WORKING ---

  test "user sends input transitions to WORKING", %{session: session} do
    sid = start_mock_session()

    session
    |> visit("/")
    |> assert_has(status_badge("IDLE"))

    # Sending input with newline triggers :idle → :working in the server
    Sam.Session.Server.send_input(sid, "hello\n")

    session
    |> assert_has(status_badge("WORKING"))
  end

  # --- Test 3: PreToolUse hook → stays WORKING ---

  test "pre_tool_call hook keeps status WORKING", %{session: session} do
    sid = start_mock_session()

    session
    |> visit("/")
    |> assert_has(status_badge("IDLE"))

    # Send PRE_TOOL command via stdin — mock agent fires the hook HTTP request
    Sam.Session.Server.send_input(sid, "PRE_TOOL Read some/file.ex\n")

    session
    |> assert_has(status_badge("WORKING"))
  end

  # --- Test 4: PostToolUse + idle timeout → IDLE ---

  test "post_tool_call with idle timeout returns to IDLE", %{session: session} do
    sid = start_mock_session()

    session
    |> visit("/")
    |> assert_has(status_badge("IDLE"))

    # Trigger working via PRE_TOOL, then POST_TOOL to start idle timer
    Sam.Session.Server.send_input(sid, "PRE_TOOL Read file.ex\n")

    session
    |> assert_has(status_badge("WORKING"))

    Sam.Session.Server.send_input(sid, "POST_TOOL Read\n")

    # Default idle timeout is 5s; wait up to 8s for IDLE
    await_status(session, "IDLE", 8_000)
  end

  # --- Test 5: Long-running tool stays WORKING ---

  test "long-running tool stays WORKING", %{session: session} do
    sid = start_mock_session()

    session
    |> visit("/")
    |> assert_has(status_badge("IDLE"))

    Sam.Session.Server.send_input(sid, "PRE_TOOL Bash long running command\n")

    session
    |> assert_has(status_badge("WORKING"))

    # Check it's still WORKING after a few seconds (no POST_TOOL sent)
    Process.sleep(3_000)

    session
    |> assert_has(status_badge("WORKING"))

    Process.sleep(3_000)

    session
    |> assert_has(status_badge("WORKING"))
  end

  # --- Test 6: Multiple tools in sequence stays WORKING ---

  test "multiple tools in quick sequence stays WORKING", %{session: session} do
    sid = start_mock_session()

    session
    |> visit("/")
    |> assert_has(status_badge("IDLE"))

    # PRE_TOOL → POST_TOOL → PRE_TOOL in quick succession
    Sam.Session.Server.send_input(sid, "PRE_TOOL Read file1.ex\n")
    Process.sleep(200)
    Sam.Session.Server.send_input(sid, "POST_TOOL Read\n")
    Process.sleep(200)
    Sam.Session.Server.send_input(sid, "PRE_TOOL Edit file2.ex\n")

    session
    |> assert_has(status_badge("WORKING"))
  end

  # --- Test 7: Permission prompt → NEEDS_INPUT ---

  test "permission prompt transitions to NEEDS_INPUT", %{session: session} do
    sid = start_mock_session()

    session
    |> visit("/")
    |> assert_has(status_badge("IDLE"))

    Sam.Session.Server.send_input(sid, "PERMISSION execute dangerous command\n")

    await_status(session, "NEEDS_INPUT", 5_000)
  end

  # --- Test 8: Exit 0 → DONE ---

  test "exit 0 transitions to DONE", %{session: session} do
    sid = start_mock_session()

    session
    |> visit("/")
    |> assert_has(status_badge("IDLE"))

    Sam.Session.Server.send_input(sid, "EXIT 0\n")

    await_status(session, "DONE", 5_000)
  end

  # --- Test 9: Exit non-zero → ERROR ---

  test "exit non-zero transitions to ERROR", %{session: session} do
    sid = start_mock_session()

    session
    |> visit("/")
    |> assert_has(status_badge("IDLE"))

    Sam.Session.Server.send_input(sid, "EXIT 1\n")

    await_status(session, "ERROR", 5_000)
  end

  # ============================================================
  # Subagent tracking (tests 10–15)
  # ============================================================

  describe "subagent tracking" do
    # --- Test 10: Agent PreToolUse → agent row appears as WORKING ---

    test "agent pre_tool_call adds a WORKING agent row", %{session: session} do
      sid = start_mock_session()

      session
      |> visit("/")
      |> assert_has(status_badge("IDLE"))

      # Spawn a subagent via the Agent tool hook
      Sam.Session.Server.send_input(sid, "PRE_TOOL Agent exploring codebase\n")

      # A separate subagent row (not the main row) should appear with WORKING status
      # The main row has class "agent-row selected" — subagent rows should not
      session
      |> assert_has(css(".agent-row:not(.selected)", text: "exploring codebase"))

      session
      |> assert_has(css(".agent-row:not(.selected) .agent-status.working", text: "WORKING"))
    end

    # --- Test 11: Agent PostToolUse → agent shows DONE ---

    test "agent post_tool_call marks agent row as DONE", %{session: session} do
      sid = start_mock_session()

      session
      |> visit("/")
      |> assert_has(status_badge("IDLE"))

      Sam.Session.Server.send_input(sid, "PRE_TOOL Agent exploring codebase\n")

      session
      |> assert_has(css(".agent-row:not(.selected)", text: "exploring codebase"))

      Sam.Session.Server.send_input(sid, "POST_TOOL Agent\n")

      # Agent row should transition to DONE
      await_status(session, "IDLE", 8_000)

      session
      |> assert_has(css(".agent-row:not(.selected) .agent-status.done", text: "DONE"))
    end

    # --- Test 12: Multiple agents → separate rows ---

    test "multiple agents show separate rows", %{session: session} do
      sid = start_mock_session()

      session
      |> visit("/")
      |> assert_has(status_badge("IDLE"))

      Sam.Session.Server.send_input(sid, "PRE_TOOL Agent exploring codebase\n")
      Process.sleep(300)
      Sam.Session.Server.send_input(sid, "PRE_TOOL Agent writing tests\n")

      # Both subagent rows should be visible as distinct rows (not the main row)
      session
      |> assert_has(css(".agent-row:not(.selected)", text: "exploring codebase"))

      session
      |> assert_has(css(".agent-row:not(.selected)", text: "writing tests"))

      # Should have at least 3 agent rows total (main + 2 subagents)
      session
      |> assert_has(css(".agent-row", count: 3))
    end

    # --- Test 13: Main idle + agents working → BACKGROUND ---

    test "main idle with agents working shows BACKGROUND status", %{session: session} do
      sid = start_mock_session()

      session
      |> visit("/")
      |> assert_has(status_badge("IDLE"))

      # Start main tool work, then spawn a subagent
      Sam.Session.Server.send_input(sid, "PRE_TOOL Bash running build\n")

      session
      |> assert_has(status_badge("WORKING"))

      # Spawn a subagent
      Sam.Session.Server.send_input(sid, "PRE_TOOL Agent exploring codebase\n")
      Process.sleep(300)

      # Main tool completes, but subagent is still working
      Sam.Session.Server.send_input(sid, "POST_TOOL Bash\n")

      # Status should be BACKGROUND (main idle, subagent still working)
      await_status(session, "BACKGROUND", 8_000)
    end

    # --- Test 14: Last agent completes → IDLE ---

    test "last agent completing transitions from BACKGROUND to IDLE", %{session: session} do
      sid = start_mock_session()

      session
      |> visit("/")
      |> assert_has(status_badge("IDLE"))

      # Set up BACKGROUND state: main tool + subagent, then main completes
      Sam.Session.Server.send_input(sid, "PRE_TOOL Bash running build\n")

      session
      |> assert_has(status_badge("WORKING"))

      Sam.Session.Server.send_input(sid, "PRE_TOOL Agent exploring codebase\n")
      Process.sleep(300)
      Sam.Session.Server.send_input(sid, "POST_TOOL Bash\n")

      await_status(session, "BACKGROUND", 8_000)

      # Now the last subagent completes
      Sam.Session.Server.send_input(sid, "POST_TOOL Agent\n")

      # Should transition back to IDLE
      await_status(session, "IDLE", 8_000)
    end

    # --- Test 15: User sends input while BACKGROUND → WORKING ---

    test "user input during BACKGROUND transitions to WORKING", %{session: session} do
      sid = start_mock_session()

      session
      |> visit("/")
      |> assert_has(status_badge("IDLE"))

      # Set up BACKGROUND state
      Sam.Session.Server.send_input(sid, "PRE_TOOL Bash running build\n")

      session
      |> assert_has(status_badge("WORKING"))

      Sam.Session.Server.send_input(sid, "PRE_TOOL Agent exploring codebase\n")
      Process.sleep(300)
      Sam.Session.Server.send_input(sid, "POST_TOOL Bash\n")

      await_status(session, "BACKGROUND", 8_000)

      # User sends input — should override to WORKING
      Sam.Session.Server.send_input(sid, "hello\n")

      session
      |> assert_has(status_badge("WORKING"))
    end
  end

  # ============================================================
  # Session lifecycle (tests 16–18)
  # ============================================================

  describe "session lifecycle" do
    test "terminate removes session from dashboard", %{session: session} do
      _sid = start_mock_session()

      session =
        session
        |> visit("/")
        |> assert_has(css(".sam-footer", text: "1 SESSION"))

      # Click TERMINATE button
      session
      |> find(css("button", text: "TERMINATE"))
      |> Wallaby.Element.click()

      # Session should be gone
      session
      |> assert_has(css(".sam-footer", text: "0 SESSIONS"))
    end

    test "kill all removes all sessions from dashboard", %{session: session} do
      _sid1 = start_mock_session()
      _sid2 = start_mock_session()

      session =
        session
        |> visit("/")
        |> assert_has(css(".sam-footer", text: "2 SESSIONS"))

      # Click KILL ALL button
      session
      |> find(css("button", text: "KILL ALL"))
      |> Wallaby.Element.click()

      # Should show 0 sessions
      session
      |> assert_has(css(".sam-footer", text: "0 SESSIONS"))
    end

    test "terminate does not create ghost sessions", %{session: session} do
      _sid = start_mock_session()

      session =
        session
        |> visit("/")
        |> assert_has(css(".sam-footer", text: "1 SESSION"))

      # Click TERMINATE
      session
      |> find(css("button", text: "TERMINATE"))
      |> Wallaby.Element.click()

      # Wait to ensure no restart
      Process.sleep(2_000)

      # Still 0 sessions — no ghost restart by supervisor
      session
      |> assert_has(css(".sam-footer", text: "0 SESSIONS"))
    end
  end
end
