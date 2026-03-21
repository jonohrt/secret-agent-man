defmodule Sam.Session.TranscriptWatcher do
  @moduledoc """
  Watches Claude Code's JSONL transcript file for a session.
  Emits parser events (tool_call, tool_result, assistant_response) that drive
  the Server's status state machine.

  Discovery: finds the JSONL file created closest to when this watcher started,
  using file birthtime on macOS. Falls back to most recently modified on Linux.
  """
  use GenServer
  require Logger

  @poll_interval_ms 1_000
  @discovery_timeout_ms 30_000
  @claude_projects_dir Path.join(System.user_home!(), ".claude/projects")

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    session_id = Map.fetch!(opts, :session_id)
    workdir = Map.get(opts, :workdir)
    test_path = Map.get(opts, :_test_jsonl_path)
    test_project_dir = Map.get(opts, :_test_project_dir)

    started_at = System.os_time(:second)

    state = %{
      session_id: session_id,
      workdir: workdir,
      project_dir_override: test_project_dir,
      path: test_path,
      offset: if(test_path, do: file_size(test_path), else: 0),
      line_buffer: "",
      started_at: started_at
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, %{path: nil} = state) do
    case find_session_jsonl(state) do
      nil ->
        schedule_poll()
        {:noreply, state}

      path ->
        Logger.info("[TranscriptWatcher] Locked onto #{Path.basename(path)}")
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

  ## Discovery

  defp find_session_jsonl(state) do
    dir = state.project_dir_override || project_dir(state.workdir)
    now = System.os_time(:second)
    age = now - state.started_at

    case File.ls(dir) do
      {:ok, files} ->
        jsonl_files =
          files
          |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
          |> Enum.map(&Path.join(dir, &1))

        # Try birthtime-based matching first (macOS)
        case find_by_birthtime(jsonl_files, state.started_at) do
          nil when age > div(@discovery_timeout_ms, 1000) ->
            # Fallback: pick most recently modified after timeout
            Logger.warning("[TranscriptWatcher] Birthtime match failed, falling back to mtime")
            find_by_mtime(jsonl_files)

          nil ->
            nil

          path ->
            path
        end

      _ ->
        nil
    end
  end

  # Find JSONL created within 10 seconds of watcher start (covers startup race)
  defp find_by_birthtime(paths, started_at) do
    cutoff = started_at - 10

    paths
    |> Enum.map(fn path -> {path, get_birthtime(path)} end)
    |> Enum.filter(fn {_, bt} -> bt >= cutoff end)
    |> Enum.sort_by(fn {_, bt} -> bt end, :desc)
    |> case do
      [{path, _} | _] -> path
      [] -> nil
    end
  end

  defp find_by_mtime(paths) do
    paths
    |> Enum.map(fn path ->
      case File.stat(path, time: :posix) do
        {:ok, %{mtime: mt}} -> {path, mt}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_, mt} -> mt end, :desc)
    |> case do
      [{path, _} | _] -> path
      [] -> nil
    end
  end

  defp get_birthtime(path) do
    case :os.type() do
      {:unix, :darwin} ->
        case System.cmd("/usr/bin/stat", ["-f", "%B", path], stderr_to_stdout: true) do
          {output, 0} ->
            case Integer.parse(String.trim(output)) do
              {ts, _} -> ts
              :error -> 0
            end

          _ ->
            0
        end

      _ ->
        # Linux: no birthtime, return 0 so birthtime matching skips
        0
    end
  end

  ## Parsing

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

  # Assistant with tool_use → working
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
    else
      # Text-only assistant response → start idle timer
      Phoenix.PubSub.broadcast(
        Sam.PubSub,
        "session:#{session_id}",
        {:parser_event, session_id,
         %{type: :tool_result, tool: "response", timestamp: DateTime.utc_now()}}
      )
    end
  end

  # Tool results
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

  # Turn end
  defp handle_record(%{"type" => "system", "subtype" => "turn_duration"}, session_id) do
    Phoenix.PubSub.broadcast(
      Sam.PubSub,
      "session:#{session_id}",
      {:parser_event, session_id,
       %{type: :tool_result, tool: "turn_end", timestamp: DateTime.utc_now()}}
    )
  end

  defp handle_record(_, _), do: :ok

  defp project_dir(nil) do
    cwd = File.cwd!()
    encoded = String.replace(cwd, "/", "-")
    Path.join(@claude_projects_dir, encoded)
  end

  defp project_dir(workdir) do
    encoded = String.replace(workdir, "/", "-")
    Path.join(@claude_projects_dir, encoded)
  end
end
