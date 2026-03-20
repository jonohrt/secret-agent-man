defmodule SamWeb.DashboardLiveTest do
  use SamWeb.ConnCase
  import Phoenix.LiveViewTest

  test "renders empty dashboard", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "+"
    assert html =~ "Select or create a session" || html =~ "No active agents" || html =~ "Activity"
  end

  test "opens new session dialog", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    view |> element(".tab-new-btn") |> render_click()
    assert render(view) =~ "New Session" || render(view) =~ "new-session" || render(view) =~ "Agent"
  end
end
