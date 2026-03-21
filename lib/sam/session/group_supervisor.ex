defmodule Sam.Session.GroupSupervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  def start_session(opts) do
    DynamicSupervisor.start_child(Sam.SessionSupervisor, {__MODULE__, opts})
  end

  def terminate_session(session_id) do
    case Registry.lookup(Sam.ProcessRegistry, session_id) do
      [{server_pid, _}] ->
        # Find the GroupSupervisor that owns this server
        # The server's parent is the GroupSupervisor
        case find_group_supervisor(server_pid) do
          nil -> {:error, :not_found}
          group_pid -> DynamicSupervisor.terminate_child(Sam.SessionSupervisor, group_pid)
        end

      [] ->
        {:error, :not_found}
    end
  end

  defp find_group_supervisor(server_pid) do
    # Walk DynamicSupervisor children to find which GroupSupervisor contains this server
    DynamicSupervisor.which_children(Sam.SessionSupervisor)
    |> Enum.find_value(fn {_, group_pid, :supervisor, _} ->
      children = Supervisor.which_children(group_pid)

      if Enum.any?(children, fn {_, pid, _, _} -> pid == server_pid end) do
        group_pid
      end
    end)
  end

  @impl true
  def init(opts) do
    session_id = Map.fetch!(opts, :session_id)
    command = Map.fetch!(opts, :command)
    claude_session_id = Map.get(opts, :claude_session_id)

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
        id: Sam.Session.TranscriptWatcher,
        start:
          {Sam.Session.TranscriptWatcher, :start_link,
           [
             %{
               session_id: session_id,
               workdir: Map.get(opts, :workdir),
               claude_session_id: claude_session_id
             }
           ]}
      },
      %{
        id: Sam.Session.PTY,
        start:
          {Sam.Session.PTY, :start_link,
           [
             %{
               session_id: session_id,
               command: command,
               workdir: Map.get(opts, :workdir)
             }
           ]}
      },
      %{
        id: Sam.Session.JournalFinder,
        start:
          {Sam.Session.JournalFinder, :start_link,
           [%{session_id: session_id, watch_dir: journal_watch_dir(Map.get(opts, :workdir))}]},
        restart: :temporary
      }
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp journal_watch_dir(nil) do
    cwd = File.cwd!()
    encoded = String.replace(cwd, "/", "-")
    Path.join(Path.join(System.user_home!(), ".claude/projects"), encoded)
  end

  defp journal_watch_dir(workdir) do
    encoded = String.replace(workdir, "/", "-")
    Path.join(Path.join(System.user_home!(), ".claude/projects"), encoded)
  end
end
