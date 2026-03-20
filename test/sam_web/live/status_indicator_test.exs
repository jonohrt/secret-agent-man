defmodule SamWeb.Live.StatusIndicatorTest do
  use SamWeb.FeatureCase, async: false

  @e2e_port 4042

  setup do
    # Test config has server: false, so we start Bandit manually for Wallaby.
    # Use localhost (not 127.0.0.1) to match the endpoint's configured host,
    # otherwise LiveSocket rejects the websocket origin check.
    {:ok, server_pid} =
      Bandit.start_link(
        plug: SamWeb.Endpoint,
        port: @e2e_port,
        scheme: :http,
        ip: {127, 0, 0, 1}
      )

    Application.put_env(:wallaby, :base_url, "http://localhost:#{@e2e_port}")
    # Disable js_logger to avoid :log device errors in test
    Application.put_env(:wallaby, :js_logger, nil)

    on_exit(fn ->
      Process.exit(server_pid, :normal)
    end)

    :ok
  end

  @tag :e2e
  feature "status dot transitions through working and idle", %{session: session} do
    # Visit dashboard
    session = visit(session, "/")

    # Open the deploy dialog
    session = click(session, Query.button("+ DEPLOY AGENT"))

    # Fill in the form
    session =
      session
      |> fill_in(Query.css("input[name='name']"), with: "e2e-status-test")
      |> fill_in(Query.css("input[name='workdir']"), with: System.tmp_dir!())

    # Submit the form
    session = click(session, Query.css("button[type='submit'].modal-submit"))

    # Wait for session tab to appear
    assert_has(session, Query.css(".sam-tab", minimum: 1))

    # Find the session ID from the registry
    session_ids = Sam.Session.Server.list_sessions()
    session_id = Enum.find(session_ids, &String.contains?(&1, "session-"))

    assert session_id != nil, "Expected a session to exist after creation"

    # Broadcast a tool_call event to trigger :working status
    Phoenix.PubSub.broadcast(
      Sam.PubSub,
      "session:#{session_id}",
      {:parser_event, session_id,
       %{type: :tool_call, tool: "Read", timestamp: DateTime.utc_now()}}
    )

    # Give LiveView time to process the PubSub message and re-render
    Process.sleep(500)

    # Assert status dot has "working" class (appears in tab bar, status bar, and agents panel)
    assert_has(session, Query.css(".status-dot.working", minimum: 1))

    # Wait for idle timeout (5s default) plus buffer for LiveView re-render
    Process.sleep(6000)

    # Assert status dot transitions to "idle"
    assert_has(session, Query.css(".status-dot.idle", minimum: 1))

    # Clean up: terminate all session children
    on_exit(fn ->
      children = DynamicSupervisor.which_children(Sam.SessionSupervisor)

      for {_, pid, _, _} <- children do
        DynamicSupervisor.terminate_child(Sam.SessionSupervisor, pid)
      end
    end)
  end
end
