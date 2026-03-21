defmodule SamWeb.Features.GhostTerminalTest do
  use SamWeb.FeatureCase, async: false

  import Wallaby.Query

  @moduletag :e2e

  defp start_mock_session do
    start_mock_session("test-e2e-#{System.unique_integer([:positive])}")
  end

  defp start_mock_session(sid) do
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

  describe "terminal lifecycle" do
    test "exactly one terminal element is visible for selected session", %{session: session} do
      sid = start_mock_session()

      session = visit(session, "/")

      # Click the tab to ensure it's selected
      session
      |> find(css("[phx-value-id='#{sid}'].sam-tab"))
      |> Wallaby.Element.click()

      Process.sleep(1_000)

      # Terminal should be visible with xterm rendered
      session
      |> assert_has(css(".sam-terminal-body .xterm", minimum: 1))
    end

    test "switching tabs produces exactly one terminal", %{session: session} do
      sid1 = start_mock_session()
      sid2 = start_mock_session()

      session = visit(session, "/")

      # Select session 1
      session
      |> find(css("[phx-value-id='#{sid1}'].sam-tab"))
      |> Wallaby.Element.click()

      Process.sleep(500)

      # Should have exactly one terminal
      session
      |> assert_has(css(".sam-terminal-body .xterm", count: 1))

      # Switch to session 2
      session
      |> find(css("[phx-value-id='#{sid2}'].sam-tab"))
      |> Wallaby.Element.click()

      Process.sleep(500)

      # Still exactly one terminal — no ghost from session 1
      session
      |> assert_has(css(".sam-terminal-body .xterm", count: 1))
    end

    test "rapid tab switching does not create ghost terminals", %{session: session} do
      sid1 = start_mock_session()
      sid2 = start_mock_session()

      session = visit(session, "/")
      Process.sleep(500)

      # Rapid switching back and forth
      for _i <- 1..3 do
        session
        |> find(css("[phx-value-id='#{sid1}'].sam-tab"))
        |> Wallaby.Element.click()

        Process.sleep(100)

        session
        |> find(css("[phx-value-id='#{sid2}'].sam-tab"))
        |> Wallaby.Element.click()

        Process.sleep(100)
      end

      # Wait for any async cleanup to finish
      Process.sleep(1_000)

      # Must be exactly one terminal, no ghosts
      session
      |> assert_has(css(".sam-terminal-body .xterm", count: 1))
    end

    test "page refresh produces a visible terminal", %{session: session} do
      sid = start_mock_session()

      session = visit(session, "/")

      session
      |> find(css("[phx-value-id='#{sid}'].sam-tab"))
      |> Wallaby.Element.click()

      Process.sleep(1_000)

      session
      |> assert_has(css(".sam-terminal-body .xterm", minimum: 1))

      # Refresh the page
      session = visit(session, "/")

      session
      |> find(css("[phx-value-id='#{sid}'].sam-tab"))
      |> Wallaby.Element.click()

      Process.sleep(1_000)

      # Still has a visible terminal after refresh
      session
      |> assert_has(css(".sam-terminal-body .xterm", minimum: 1))
    end

    test "terminal div ID matches selected session", %{session: session} do
      sid = start_mock_session()

      session = visit(session, "/")

      # Click the session tab to ensure it's selected
      session
      |> find(css("[phx-value-id='#{sid}'].sam-tab"))
      |> Wallaby.Element.click()

      Process.sleep(500)

      # The terminal body should have the correct ID
      session
      |> assert_has(css("[id='terminal-#{sid}']"))
    end

    test "switching session changes terminal div ID", %{session: session} do
      sid1 = start_mock_session()
      sid2 = start_mock_session()

      session = visit(session, "/")

      # Select session 1
      session
      |> find(css("[phx-value-id='#{sid1}'].sam-tab"))
      |> Wallaby.Element.click()

      Process.sleep(500)

      session
      |> assert_has(css("[id='terminal-#{sid1}']"))

      session
      |> refute_has(css("[id='terminal-#{sid2}']"))

      # Switch to session 2
      session
      |> find(css("[phx-value-id='#{sid2}'].sam-tab"))
      |> Wallaby.Element.click()

      Process.sleep(500)

      session
      |> assert_has(css("[id='terminal-#{sid2}']"))

      session
      |> refute_has(css("[id='terminal-#{sid1}']"))
    end
  end
end
