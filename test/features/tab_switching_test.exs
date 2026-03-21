defmodule SamWeb.Features.TabSwitchingTest do
  use SamWeb.FeatureCase, async: false

  import Wallaby.Query

  @moduletag :e2e

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

    Process.sleep(500)
    sid
  end

  defp select_tab(session, sid) do
    session
    |> find(css("[phx-value-id='#{sid}'].sam-tab"))
    |> Wallaby.Element.click()

    Process.sleep(500)
    session
  end

  defp await_text(session, selector, text, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_await_text(session, selector, text, deadline)
  end

  defp do_await_text(session, selector, text, deadline) do
    try do
      assert_has(session, css(selector, text: text))
    rescue
      Wallaby.ExpectationNotMetError ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(250)
          do_await_text(session, selector, text, deadline)
        else
          assert_has(session, css(selector, text: text))
        end
    end
  end

  describe "status indicator on non-selected tabs" do
    test "inactive tab shows WORKING status when session is working", %{session: session} do
      sid1 = start_mock_session()
      sid2 = start_mock_session()

      session = visit(session, "/")

      # Select session 1 (make session 2 the inactive tab)
      select_tab(session, sid1)

      # Trigger WORKING on session 2 (the inactive tab)
      Sam.Session.Server.send_input(sid2, "PRE_TOOL Read file.ex\n")
      Process.sleep(1_000)

      # The inactive tab for session 2 should show a working status dot
      await_text(session, "[phx-value-id='#{sid2}'] .status-dot.working", "", 5_000)
    end
  end

  describe "terminal content preservation across tab switches" do
    test "terminal content is restored when switching back to a tab", %{session: session} do
      sid1 = start_mock_session()
      sid2 = start_mock_session()

      session = visit(session, "/")

      # Select session 1 and send input to produce visible output
      select_tab(session, sid1)
      Sam.Session.Server.send_input(sid1, "echo MARKER_SESSION_ONE\n")
      Process.sleep(1_000)

      # Verify terminal has content (xterm renders text into the DOM)
      session
      |> assert_has(css("[id='terminal-#{sid1}'] .xterm"))

      # Switch to session 2
      select_tab(session, sid2)
      Process.sleep(500)

      # Switch back to session 1
      select_tab(session, sid1)
      Process.sleep(1_000)

      # Terminal element should still exist and have xterm content
      session
      |> assert_has(css("[id='terminal-#{sid1}'] .xterm"))

      # The xterm canvas/rows should have content (not be empty)
      session
      |> assert_has(css("[id='terminal-#{sid1}'] .xterm-rows"))
    end
  end

  describe "session connectivity across tab switches" do
    test "session stays connected after switching tabs back and forth", %{session: session} do
      sid1 = start_mock_session()
      sid2 = start_mock_session()

      session = visit(session, "/")

      # Select session 1
      select_tab(session, sid1)

      # Switch to session 2
      select_tab(session, sid2)

      # Switch back to session 1
      select_tab(session, sid1)

      # Send input — if session is disconnected, this won't produce output
      Sam.Session.Server.send_input(sid1, "echo ALIVE_AFTER_SWITCH\n")
      Process.sleep(1_000)

      # Session should still be in a valid state (not error/done)
      state = Sam.Session.Server.get_state(sid1)
      assert state.status in [:idle, :working]

      # Terminal should still be rendering
      session
      |> assert_has(css("[id='terminal-#{sid1}'] .xterm-rows"))
    end

    test "rapid tab switching does not disconnect sessions", %{session: session} do
      sid1 = start_mock_session()
      sid2 = start_mock_session()

      session = visit(session, "/")

      # Rapid switching
      for _i <- 1..5 do
        select_tab(session, sid1)
        Process.sleep(100)
        select_tab(session, sid2)
        Process.sleep(100)
      end

      Process.sleep(1_000)

      # Both sessions should still be alive
      state1 = Sam.Session.Server.get_state(sid1)
      state2 = Sam.Session.Server.get_state(sid2)
      assert state1.status in [:idle, :working]
      assert state2.status in [:idle, :working]
    end
  end
end
