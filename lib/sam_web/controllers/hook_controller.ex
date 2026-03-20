defmodule SamWeb.HookController do
  use SamWeb, :controller

  def create(conn, params) do
    session_id = params["session_id"]

    case Registry.lookup(Sam.ProcessRegistry, session_id) do
      [{_pid, _}] ->
        Sam.Session.Server.push_hook_event(session_id, params)
        json(conn, %{status: "ok"})

      [] ->
        conn |> put_status(404) |> json(%{error: "session not found"})
    end
  end
end
