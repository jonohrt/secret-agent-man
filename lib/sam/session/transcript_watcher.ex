defmodule Sam.Session.TranscriptWatcher do
  @moduledoc """
  Watches Claude Code's JSONL transcript file for a session.
  Emits parser events (tool_call, tool_result, turn_end) that drive
  the Server's status state machine.

  The JSONL path is constructed deterministically from the claude_session_id
  passed when spawning Claude Code with --session-id.
  """
  use GenServer
  require Logger

  @poll_interval_ms 1_000
  @claude_projects_dir Path.join(System.user_home!(), ".claude/projects")

  def start_link(opts) do
    session_id = Map.fetch!(opts, :session_id)
    name = {:via, Registry, {Sam.ProcessRegistry, {:transcript_watcher, session_id}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    session_id = Map.fetch!(opts, :session_id)
    workdir = Map.get(opts, :workdir)
    claude_session_id = Map.get(opts, :claude_session_id)
    test_path = Map.get(opts, :_test_jsonl_path)
    test_project_dir = Map.get(opts, :_test_project_dir)

    path =
      cond do
        test_path != nil ->
          test_path

        claude_session_id != nil ->
          dir = test_project_dir || project_dir(workdir)
          Path.join(dir, "#{claude_session_id}.jsonl")

        true ->
          nil
      end

    state = %{
      session_id: session_id,
      workdir: workdir,
      path: path,
      offset: if(path && File.exists?(path), do: file_size(path), else: 0),
      line_buffer: "",
      waiting_for_file: path != nil && !File.exists?(path)
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, %{waiting_for_file: true, path: path} = state) when path != nil do
    if File.exists?(path) do
      Logger.info("[TranscriptWatcher] JSONL file appeared: #{Path.basename(path)}")
      offset = file_size(path)
      schedule_poll()
      {:noreply, %{state | waiting_for_file: false, offset: offset}}
    else
      schedule_poll()
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:poll, %{path: nil} = state) do
    # No claude_session_id — nothing to watch
    schedule_poll()
    {:noreply, state}
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

  def handle_info({:journal_found, _path}, state) do
    # Legacy — JournalFinder removed, TranscriptWatcher uses deterministic path
    {:noreply, state}
  end

  ## Helpers

  defp extract_tool_description("Bash", %{"description" => d}) when is_binary(d) and d != "", do: d
  defp extract_tool_description("Bash", %{"command" => c}) when is_binary(c), do: String.slice(c, 0, 80)
  defp extract_tool_description("Read", %{"file_path" => f}) when is_binary(f), do: Path.basename(f)
  defp extract_tool_description("Edit", %{"file_path" => f}) when is_binary(f), do: Path.basename(f)
  defp extract_tool_description("Write", %{"file_path" => f}) when is_binary(f), do: Path.basename(f)
  defp extract_tool_description("Glob", %{"pattern" => p}) when is_binary(p), do: p
  defp extract_tool_description("Grep", %{"pattern" => p}) when is_binary(p), do: p
  defp extract_tool_description("Agent", %{"description" => d}) when is_binary(d) and d != "", do: d
  defp extract_tool_description("Agent", %{"prompt" => p}) when is_binary(p), do: String.slice(p, 0, 80)
  defp extract_tool_description("WebFetch", %{"url" => u}) when is_binary(u), do: String.slice(u, 0, 80)
  defp extract_tool_description("WebSearch", %{"query" => q}) when is_binary(q), do: q
  defp extract_tool_description(_, %{"description" => d}) when is_binary(d) and d != "", do: d
  defp extract_tool_description(_, _), do: nil

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

  # Assistant message → always means Claude is working/responding
  defp handle_record(%{"message" => %{"role" => "assistant", "content" => content}}, session_id)
       when is_list(content) do
    tool_uses = Enum.filter(content, &(is_map(&1) and &1["type"] == "tool_use"))

    if tool_uses != [] do
      tool = hd(tool_uses)
      tool_name = tool["name"] || "unknown"
      input = tool["input"] || %{}

      # Extract meaningful context from tool input
      description = extract_tool_description(tool_name, input)

      Phoenix.PubSub.broadcast(
        Sam.PubSub,
        "session:#{session_id}",
        {:parser_event, session_id,
         %{
           type: :tool_call,
           tool: tool_name,
           description: description,
           file: input["file_path"],
           timestamp: DateTime.utc_now()
         }}
      )
    else
      # Text-only assistant response — extract snippet for summarizer
      text_snippet =
        content
        |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
        |> Enum.map(& &1["text"])
        |> Enum.join(" ")
        |> String.slice(0, 200)

      Phoenix.PubSub.broadcast(
        Sam.PubSub,
        "session:#{session_id}",
        {:parser_event, session_id,
         %{type: :assistant_response, text: text_snippet, timestamp: DateTime.utc_now()}}
      )
    end
  end

  # User message with tool_result content (list)
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

  # User message with string content (new prompt submitted)
  defp handle_record(%{"type" => "user", "message" => %{"content" => content}}, session_id)
       when is_binary(content) and content != "" do
    Phoenix.PubSub.broadcast(
      Sam.PubSub,
      "session:#{session_id}",
      {:parser_event, session_id,
       %{type: :user_prompt, text: String.slice(content, 0, 200), timestamp: DateTime.utc_now()}}
    )
  end

  # Progress records (bash_progress, mcp_progress) — tool still actively running
  defp handle_record(%{"type" => "progress", "data" => %{"type" => type}}, session_id)
       when type in ["bash_progress", "mcp_progress"] do
    Phoenix.PubSub.broadcast(
      Sam.PubSub,
      "session:#{session_id}",
      {:parser_event, session_id, %{type: :tool_progress, timestamp: DateTime.utc_now()}}
    )
  end

  # Turn end — definitive idle signal
  defp handle_record(%{"type" => "system", "subtype" => "turn_duration"}, session_id) do
    Phoenix.PubSub.broadcast(
      Sam.PubSub,
      "session:#{session_id}",
      {:parser_event, session_id, %{type: :turn_end, timestamp: DateTime.utc_now()}}
    )
  end

  defp handle_record(_, _), do: :ok

  def project_dir(nil) do
    cwd = File.cwd!()
    encoded = String.replace(cwd, "/", "-")
    Path.join(@claude_projects_dir, encoded)
  end

  def project_dir(workdir) do
    encoded = String.replace(workdir, "/", "-")
    Path.join(@claude_projects_dir, encoded)
  end
end
