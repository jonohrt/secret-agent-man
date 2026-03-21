defmodule SamWeb.DashboardLiveTest do
  use SamWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "create_session with blank workdir defaults to cwd", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    sessions_before = Sam.Session.Server.list_sessions()

    # Open the new session dialog first
    view |> element(".sam-btn-deploy") |> render_click()

    # Submit the create_session form with blank workdir
    view
    |> element("form[phx-submit=create_session]")
    |> render_submit(%{
      "name" => "test-workdir-default",
      "agent_type" => "claude_code",
      "workdir" => "",
      "prompt" => ""
    })

    # Find the session we just created by diffing before/after
    sessions_after = Sam.Session.Server.list_sessions()
    [session_id] = sessions_after -- sessions_before

    on_exit(fn ->
      Sam.Session.Server.stop(session_id)
    end)

    # Verify workdir is non-nil (defaulted to File.cwd())
    state = Sam.Session.Server.get_state(session_id)
    assert state.workdir != nil, "Expected workdir to be non-nil, got nil"
    assert state.workdir == File.cwd!()
  end

  test "renders empty dashboard", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "DEPLOY AGENT"
    assert html =~ "ACTIVITY FEED"
    assert html =~ "AGENTS"
  end

  test "opens new session dialog", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    view |> element(".sam-btn-deploy") |> render_click()

    assert render(view) =~ "New Operation" || render(view) =~ "DEPLOY"
  end

  test "elapsed time renders and ticks", %{conn: conn} do
    # Start a session BEFORE mounting the LiveView so it appears on load
    session_id = "test-uptime-e2e-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Sam.Session.Server.start_link(%{
        session_id: session_id,
        name: "Uptime Test"
      })

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    # Mount after session exists — LiveView will load and auto-select it
    {:ok, view, _static_html} = live(conn, "/")

    # Use render/1 to get the connected LiveView HTML
    html = render(view)

    # Status bar should render with uptime format HH:MM:SS
    assert html =~ "Uptime Test"
    assert html =~ ~r/\d{2}:\d{2}:\d{2}/
    [time1] = Regex.run(~r/\d{2}:\d{2}:\d{2}/, html)

    # Wait for ticks to fire (1s interval), then re-render
    Process.sleep(2100)
    send(view.pid, :tick)
    html_after = render(view)

    [time2] = Regex.run(~r/\d{2}:\d{2}:\d{2}/, html_after)

    # Elapsed time should have advanced
    assert time2 > time1, "Expected uptime to advance from #{time1} but got #{time2}"
  end
end
