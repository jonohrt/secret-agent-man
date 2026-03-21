defmodule Sam.Persistence do
  use GenServer
  require Logger

  @flush_interval_ms 30_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    dets_path = Path.join(data_dir(), "sam_sessions") |> to_charlist()
    {:ok, table} = :dets.open_file(:sam_persistence, file: dets_path, type: :set)
    cleanup_stale(table)
    schedule_flush()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:flush, state) do
    flush_sessions(state.table)
    schedule_flush()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    flush_sessions(state.table)
    :dets.close(state.table)
  end

  def load_saved_sessions(table \\ :sam_persistence) do
    :dets.foldl(
      fn {_id, data}, acc -> [data | acc] end,
      [],
      table
    )
  rescue
    ArgumentError -> []
  end

  def delete_session(table \\ :sam_persistence, session_id) do
    :dets.delete(table, session_id)
  rescue
    ArgumentError -> :ok
  end

  def cleanup_stale(table \\ :sam_persistence) do
    :dets.delete_all_objects(table)
  rescue
    ArgumentError -> :ok
  end

  defp flush_sessions(table) do
    sessions = Sam.Session.Server.list_sessions()

    Enum.each(sessions, fn id ->
      try do
        state = Sam.Session.Server.get_state(id)

        serializable = %{
          session_id: state.session_id,
          name: state.name,
          status: state.status,
          agent_type: state.agent_type,
          workdir: state.workdir,
          activity: Enum.take(state.activity, 50)
        }

        :dets.insert(table, {id, serializable})
      rescue
        _ -> :ok
      end
    end)
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end

  defp data_dir do
    dir = Path.join(System.user_home!(), ".config/secret-agent-man/data")
    File.mkdir_p!(dir)
    dir
  end
end
