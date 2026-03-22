defmodule SamWeb.Router do
  use SamWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SamWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", SamWeb do
    pipe_through :browser

    live "/", DashboardLive
  end

  scope "/api", SamWeb do
    pipe_through :api
    get "/health", ApiController, :health
    get "/sessions", ApiController, :sessions
  end
end
