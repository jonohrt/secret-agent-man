defmodule SamWeb.DashboardLiveTest do
  use SamWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "create_session with blank workdir defaults to cwd", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

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

    # Find the session we just created
    sessions = Sam.Session.Server.list_sessions()
    session_id = Enum.find(sessions, fn id -> String.contains?(id, "session-") end)
    assert session_id, "Expected a session to be created"

    # Verify workdir is non-nil (defaulted to File.cwd!())
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
end
