defmodule Sam.Session.GroupSupervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  def start_session(opts) do
    DynamicSupervisor.start_child(Sam.SessionSupervisor, {__MODULE__, opts})
  end

  @impl true
  def init(opts) do
    session_id = Map.fetch!(opts, :session_id)
    command = Map.fetch!(opts, :command)

    children = [
      %{
        id: Sam.Session.Server,
        start: {Sam.Session.Server, :start_link, [opts]}
      },
      %{
        id: Sam.Session.Summarizer,
        start: {Sam.Session.Summarizer, :start_link, [%{session_id: session_id}]}
      },
      %{
        id: Sam.Session.Parser,
        start: {Sam.Session.Parser, :start_link, [%{session_id: session_id}]}
      },
      %{
        id: Sam.Session.PTY,
        start: {Sam.Session.PTY, :start_link, [%{
          session_id: session_id,
          command: command,
          workdir: Map.get(opts, :workdir)
        }]}
      }
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
