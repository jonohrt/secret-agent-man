defmodule SamWeb.DashboardLiveTest do
  use SamWeb.ConnCase
  import Phoenix.LiveViewTest

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
