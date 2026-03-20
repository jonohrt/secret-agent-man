defmodule Sam.Session.TranscriptWatcher do
  @moduledoc """
  Watches Claude Code's JSONL transcript file for a session.
  Emits parser events (tool_call, tool_result, turn_end) that drive
  the Server's status state machine.
  """
  use GenServer

  @poll_interval_ms 1_000
  @claude_projects_dir Path.join(System.user_home!(), ".claude/projects")

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    session_id = Map.fetch!(opts, :session_id)
    workdir = Map.get(opts, :workdir)
    test_path = Map.get(opts, :_test_jsonl_path)

    state = %{
      session_id: session_id,
      workdir: workdir,
      path: test_path,
      offset: if(test_path, do: file_size(test_path), else: 0),
      line_buffer: ""
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, %{path: nil} = state) do
    # Try to find the JSONL file
    case find_jsonl(state.workdir) do
      nil ->
        schedule_poll()
        {:noreply, state}

      path ->
        # Start reading from current end of file (skip history)
        offset = file_size(path)
        schedule_poll()
        {:noreply, %{state | path: path, offset: offset}}
    end
  end

  def handle_info(:poll, state) do
    case File.stat(state.path) do
      {:ok, %{size: size}} when size > state.offset ->
        case File.open(state.path, [:read, :binary]) do
          {:ok, file} ->
            :file.position(file, state.offset)
            {:ok, data} = :file.read(file, size - state.offset)
            File.close(file)

            {new_buffer, lines} = split_lines(state.line_buffer <> data)

            for line <- lines do
              process_line(line, state.session_id)
            end

            schedule_poll()
            {:noreply, %{state | offset: size, line_buffer: new_buffer}}

          _ ->
            schedule_poll()
            {:noreply, state}
        end

      _ ->
        schedule_poll()
        {:noreply, state}
    end
  end

  ## Private

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp split_lines(data) do
    parts = String.split(data, "\n")

    case parts do
      [only] ->
        {only, []}

      _ ->
        {incomplete, complete} = List.pop_at(parts, -1)
        {incomplete, Enum.reject(complete, &(&1 == ""))}
    end
  end

  defp process_line(line, session_id) do
    case Jason.decode(line) do
      {:ok, record} -> handle_record(record, session_id)
      _ -> :ok
    end
  end

  defp handle_record(%{"message" => %{"role" => "assistant", "content" => content}}, session_id)
       when is_list(content) do
    tool_uses = Enum.filter(content, &(is_map(&1) and &1["type"] == "tool_use"))

    if tool_uses != [] do
      tool_name = get_in(hd(tool_uses), ["name"]) || "unknown"

      Phoenix.PubSub.broadcast(
        Sam.PubSub,
        "session:#{session_id}",
        {:parser_event, session_id,
         %{type: :tool_call, tool: tool_name, timestamp: DateTime.utc_now()}}
      )
    end
  end

  defp handle_record(%{"message" => %{"role" => "user", "content" => content}}, session_id)
       when is_list(content) do
    tool_results = Enum.filter(content, &(is_map(&1) and &1["type"] == "tool_result"))

    if tool_results != [] do
      Phoenix.PubSub.broadcast(
        Sam.PubSub,
        "session:#{session_id}",
        {:parser_event, session_id,
         %{type: :tool_result, tool: "unknown", timestamp: DateTime.utc_now()}}
      )
    end
  end

  defp handle_record(%{"type" => "system", "subtype" => "turn_duration"}, session_id) do
    Phoenix.PubSub.broadcast(
      Sam.PubSub,
      "session:#{session_id}",
      {:parser_event, session_id,
       %{type: :tool_result, tool: "turn_end", timestamp: DateTime.utc_now()}}
    )
  end

  defp handle_record(_, _), do: :ok

  defp find_jsonl(workdir) do
    dir = project_dir(workdir)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.sort_by(
          fn path ->
            case File.stat(path) do
              {:ok, %{mtime: mtime}} -> mtime
              _ -> {{0, 0, 0}, {0, 0, 0}}
            end
          end,
          :desc
        )
        |> List.first()

      _ ->
        nil
    end
  end

  defp project_dir(nil) do
    # Default to current working directory
    cwd = File.cwd!()
    encoded = String.replace(cwd, "/", "-")
    Path.join(@claude_projects_dir, encoded)
  end

  defp project_dir(workdir) do
    encoded = String.replace(workdir, "/", "-")
    Path.join(@claude_projects_dir, encoded)
  end
end
