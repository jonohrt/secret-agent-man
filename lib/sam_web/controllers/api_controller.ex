defmodule SamWeb.ApiController do
  use SamWeb, :controller

  def health(conn, _params) do
    sessions = Sam.Session.Server.list_sessions()
    json(conn, %{
      status: "ok",
      session_count: length(sessions),
      uptime_seconds: System.monotonic_time(:second)
    })
  end

  def sessions(conn, _params) do
    sessions = Sam.Session.Server.list_sessions()
    |> Enum.map(fn id ->
      state = Sam.Session.Server.get_state(id)
      %{
        session_id: state.session_id,
        name: state.name,
        status: state.status,
        agent_type: state.agent_type,
        activity_count: length(state.activity)
      }
    end)
    json(conn, %{sessions: sessions})
  end
end
