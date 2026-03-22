defmodule SamWeb.Features.ActivityFeedTest do
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

  # Inject a summary directly into the Server's activity list via PubSub.
  defp inject_summary(sid, text) do
    Phoenix.PubSub.broadcast(
      Sam.PubSub,
      "session:#{sid}",
      {:summary, sid, %{summary: text, timestamp: DateTime.utc_now()}}
    )
  end

  # Re-select session tab to force LiveView re-render with fresh state
  defp reselect_tab(session, sid) do
    session
    |> find(css("[phx-value-id='#{sid}'].sam-tab"))
    |> Wallaby.Element.click()

    Process.sleep(500)
  end

  # Poll for an activity item to appear
  defp await_activity(session, text, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_activity(session, text, deadline)
  end

  defp do_await_activity(session, text, deadline) do
    try do
      assert_has(session, css(".activity-item", text: text))
    rescue
      Wallaby.ExpectationNotMetError ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(300)
          do_await_activity(session, text, deadline)
        else
          assert_has(session, css(".activity-item", text: text))
        end
    end
  end

  describe "activity feed panel" do
    test "activity feed panel is visible on dashboard", %{session: session} do
      _sid = start_mock_session()

      session
      |> visit("/")
      |> assert_has(css(".sam-panel-header", text: "ACTIVITY FEED"))
    end

    test "activity feed shows entries when summary events arrive", %{session: session} do
      sid = start_mock_session()

      session = visit(session, "/")
      assert_has(session, css(".sam-panel-header", text: "ACTIVITY FEED"))
      Process.sleep(1_000)

      inject_summary(sid, "Reading configuration files")
      Process.sleep(500)

      # Verify the Server stored the activity
      server_state = Sam.Session.Server.get_state(sid)
      assert length(server_state.activity) > 0

      # Re-select tab to ensure UI picks up the update
      reselect_tab(session, sid)

      await_activity(session, "Reading configuration files")
    end

    test "multiple summary events appear in feed", %{session: session} do
      sid = start_mock_session()

      session = visit(session, "/")
      assert_has(session, css(".sam-panel-header", text: "ACTIVITY FEED"))
      Process.sleep(1_000)

      inject_summary(sid, "First action")
      Process.sleep(200)
      inject_summary(sid, "Second action")
      Process.sleep(500)

      reselect_tab(session, sid)

      await_activity(session, "First action")
      await_activity(session, "Second action")
    end

    test "activity feed is empty for a fresh session with no events", %{session: session} do
      _sid = start_mock_session()

      session
      |> visit("/")
      |> assert_has(css(".sam-panel-header", text: "ACTIVITY FEED"))

      session
      |> refute_has(css(".activity-item"))
    end

    test "activity feed updates when switching between sessions", %{session: session} do
      sid1 = start_mock_session()
      sid2 = start_mock_session()

      session = visit(session, "/")
      Process.sleep(1_000)

      inject_summary(sid1, "Session one activity")
      inject_summary(sid2, "Session two activity")
      Process.sleep(500)

      # Select session 1
      reselect_tab(session, sid1)
      await_activity(session, "Session one activity")
      refute_has(session, css(".activity-item", text: "Session two activity"))

      # Switch to session 2
      reselect_tab(session, sid2)
      await_activity(session, "Session two activity")
      refute_has(session, css(".activity-item", text: "Session one activity"))
    end
  end
end
