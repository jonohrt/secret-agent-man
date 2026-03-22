defmodule Sam.Session.Server do
  use GenServer

  @idle_timeout_ms 10_000
  @needs_input_timeout_ms 7_000
  @text_idle_delay_ms 5_000
  @permission_exempt_tools ~w(Agent Task AskUserQuestion)

  defstruct [
    :session_id,
    :name,
    :agent_type,
    :branch,
    :workdir,
    :idle_timer,
    :idle_timeout_ms,
    :needs_input_timer,
    :needs_input_timeout_ms,
    :started_at,
    status: :idle,
    jsonl_turn_active: false,
    activity: [],
    agents: [],
    summary: "Awaiting directives..."
  ]

  ## Public API

  def start_link(opts) do
    session_id = Map.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  def get_state(session_id) do
    GenServer.call(via(session_id), :get_state)
  end

  def send_input(session_id, data) do
    GenServer.cast(via(session_id), {:send_input, data})
  end

  def resize(session_id, cols, rows) do
    GenServer.cast(via(session_id), {:resize, cols, rows})
  end

  def rename(session_id, new_name) do
    GenServer.call(via(session_id), {:rename, new_name})
  end

  def stop(session_id) do
    GenServer.cast(via(session_id), :stop)
  end

  def list_sessions do
    Registry.select(Sam.ProcessRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.filter(&is_binary/1)
  end

  defp via(session_id), do: {:via, Registry, {Sam.ProcessRegistry, session_id}}

  ## GenServer callbacks

  @impl true
  def init(opts) do
    session_id = Map.fetch!(opts, :session_id)
    Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

    workdir = Map.get(opts, :workdir)

    state = %__MODULE__{
      session_id: session_id,
      name: Map.get(opts, :name, session_id),
      agent_type: Map.get(opts, :agent_type, :generic),
      workdir: workdir,
      branch: detect_branch(workdir),
      idle_timeout_ms: Map.get(opts, :idle_timeout_ms, @idle_timeout_ms),
      needs_input_timeout_ms: Map.get(opts, :needs_input_timeout_ms, @needs_input_timeout_ms),
      started_at: DateTime.utc_now(),
      status: :idle
    }

    broadcast_ui_update(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, sanitize_state(state), state}
  end

  @impl true
  def handle_call({:rename, new_name}, _from, state) do
    trimmed = String.trim(new_name)

    if trimmed == "" do
      {:reply, {:error, :empty_name}, state}
    else
      state = %{state | name: trimmed}
      broadcast_ui_update(state)
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:send_input, data}, state) do
    if state.status in [:done, :error] do
      {:noreply, state}
    else
      Phoenix.PubSub.broadcast(Sam.PubSub, "session_input:#{state.session_id}", {:input, data})
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:resize, cols, rows}, state) do
    Phoenix.PubSub.broadcast(
      Sam.PubSub,
      "session_input:#{state.session_id}",
      {:resize, cols, rows}
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast(:stop, state) do
    Phoenix.PubSub.broadcast(Sam.PubSub, "session_input:#{state.session_id}", :kill)
    {:stop, :normal, state}
  end

  ## PubSub event handlers

  @impl true
  def handle_info({:parser_event, _session_id, %{type: :input_needed}}, state) do
    if state.status in [:done, :error] do
      {:noreply, state}
    else
      state = cancel_idle_timer(state)
      state = %{state | status: :needs_input}
      broadcast_ui_update(state)
      {:noreply, state}
    end
  end

  # User submitted a new prompt → working, starts a new JSONL turn
  @impl true
  def handle_info({:parser_event, _, %{type: :user_prompt}}, state) do
    if state.status in [:done, :error] do
      {:noreply, state}
    else
      state = cancel_idle_timer(state)
      state = cancel_needs_input_timer(state)
      state = %{state | status: :working, jsonl_turn_active: true}
      broadcast_ui_update(state)
      {:noreply, state}
    end
  end

  # Assistant text response (no tools) → working, with fallback idle timer
  # turn_duration may never arrive for simple text responses
  @impl true
  def handle_info({:parser_event, _, %{type: :assistant_response}}, state) do
    if state.status in [:done, :error] do
      {:noreply, state}
    else
      state = cancel_idle_timer(state)
      state = cancel_needs_input_timer(state)
      state = %{state | status: :working, jsonl_turn_active: true}
      broadcast_ui_update(state)
      # Fallback: if no turn_duration arrives within 5s, assume turn ended
      timer = Process.send_after(self(), :idle_timeout, @text_idle_delay_ms)
      {:noreply, %{state | idle_timer: timer}}
    end
  end

  # Tool still running — reset needs_input timer
  @impl true
  def handle_info({:parser_event, _, %{type: :tool_progress}}, state) do
    if state.status in [:done, :error] do
      {:noreply, state}
    else
      # If we were falsely set to needs_input, go back to working
      state =
        if state.status == :needs_input do
          %{state | status: :working}
        else
          state
        end

      state = cancel_needs_input_timer(state)
      state = start_needs_input_timer(state)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:parser_event, _, %{type: :tool_call} = event}, state) do
    if state.status in [:done, :error] do
      {:noreply, state}
    else
      # Tool starting — set working, NO idle timer (tool is still running)
      state = cancel_idle_timer(state)
      state = cancel_needs_input_timer(state)

      tool = Map.get(event, :tool, "unknown")

      # Track subagent lifecycle for Agent tools
      state =
        if tool == "Agent" do
          desc = Map.get(event, :description, "")

          agent_desc =
            case desc do
              d when is_binary(d) and d != "" -> d
              _ -> "subagent"
            end

          agent_entry = %{
            id: System.unique_integer([:positive]),
            description: agent_desc,
            status: :working,
            started_at: DateTime.utc_now()
          }

          %{state | agents: state.agents ++ [agent_entry]}
        else
          state
        end

      state = %{state | status: :working, jsonl_turn_active: true}
      broadcast_ui_update(state)

      # Start needs_input timer for non-exempt tools (permission prompts)
      state =
        if tool not in @permission_exempt_tools do
          start_needs_input_timer(state)
        else
          state
        end

      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:parser_event, _, %{type: :tool_result} = event}, state) do
    if state.status in [:done, :error] do
      {:noreply, state}
    else
      state = cancel_needs_input_timer(state)
      tool = Map.get(event, :tool, "unknown")

      # Mark first working agent as done when Agent tool completes
      state =
        if tool == "Agent" do
          mark_first_working_agent_done(state)
        else
          state
        end

      # If we were :background and no more agents are working, go idle immediately
      has_working_agents = Enum.any?(state.agents, &(&1.status == :working))

      state =
        if state.status == :background and not has_working_agents do
          %{state | status: :idle, idle_timer: nil}
        else
          state
        end

      broadcast_ui_update(state)

      # Tool finished — start idle timer (go idle if no new tool starts)
      state = cancel_idle_timer(state)
      timer = Process.send_after(self(), :idle_timeout, state.idle_timeout_ms)
      {:noreply, %{state | idle_timer: timer}}
    end
  end

  @impl true
  def handle_info({:parser_event, _, %{type: :turn_end}}, state) do
    if state.status in [:done, :error] do
      {:noreply, state}
    else
      state = cancel_idle_timer(state)
      state = cancel_needs_input_timer(state)
      state = %{state | status: :idle, jsonl_turn_active: false}
      broadcast_ui_update(state)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:parser_event, _, _}, state), do: {:noreply, state}

  @impl true
  def handle_info({:summary, _session_id, %{text: text} = payload}, state) do
    entry = %{
      type: :summary,
      text: text,
      source: Map.get(payload, :source, :heuristic),
      tool_count: Map.get(payload, :tool_count, 0),
      timestamp: DateTime.utc_now()
    }

    state = %{state | activity: [entry | state.activity] |> Enum.take(50), summary: text}
    broadcast_ui_update(state)
    {:noreply, state}
  end

  # Detect Claude Code's actual input prompt: ❯ (U+276F) preceded by a
  # newline or carriage return (with optional ANSI escapes) and followed by
  # a space. This avoids false positives from ❯ appearing in tool output,
  # file contents, or Claude Code's own rendering chrome.
  #
  # We use a regex with the /u flag for UTF-8 safety.
  @prompt_pattern ~r/[\r\n](?:\e\[[0-9;]*m)*❯(?:\e\[[0-9;]*m)* $/u

  @impl true
  def handle_info({:pty_output, _, data}, state) do
    if state.status in [:working, :needs_input] and
         not state.jsonl_turn_active and
         Regex.match?(@prompt_pattern, data) do
      state = cancel_idle_timer(state)
      state = cancel_needs_input_timer(state)
      state = %{state | status: :idle}
      broadcast_ui_update(state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:needs_input_timeout, state) do
    if state.status == :working do
      state = %{state | status: :needs_input, needs_input_timer: nil}
      broadcast_ui_update(state)
      {:noreply, state}
    else
      {:noreply, %{state | needs_input_timer: nil}}
    end
  end

  @impl true
  def handle_info(:idle_timeout, state) do
    # No output for @idle_timeout_ms — transition based on subagent status
    if state.status == :working do
      has_working_agents = Enum.any?(state.agents, &(&1.status == :working))

      new_status = if has_working_agents, do: :background, else: :idle
      state = %{state | status: new_status, idle_timer: nil, jsonl_turn_active: false}
      broadcast_ui_update(state)
      {:noreply, state}
    else
      {:noreply, %{state | idle_timer: nil}}
    end
  end

  @impl true
  def handle_info({:pty_exit, _session_id, 0}, state) do
    state = cancel_idle_timer(state)
    state = %{state | status: :done}
    broadcast_ui_update(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:pty_exit, _session_id, _code}, state) do
    state = cancel_idle_timer(state)
    state = %{state | status: :error}
    broadcast_ui_update(state)
    {:noreply, state}
  end

  # Ignore journal_found — handled by TranscriptWatcher
  @impl true
  def handle_info({:journal_found, _path}, state), do: {:noreply, state}

  ## Private helpers

  defp mark_first_working_agent_done(state) do
    {updated, _found} =
      Enum.map_reduce(state.agents, false, fn agent, found ->
        if not found and agent.status == :working do
          {%{agent | status: :done}, true}
        else
          {agent, found}
        end
      end)

    %{state | agents: updated}
  end

  defp cancel_idle_timer(%{idle_timer: nil} = state), do: state

  defp cancel_idle_timer(%{idle_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | idle_timer: nil}
  end

  defp cancel_needs_input_timer(%{needs_input_timer: nil} = state), do: state

  defp cancel_needs_input_timer(%{needs_input_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | needs_input_timer: nil}
  end

  defp start_needs_input_timer(state) do
    timer = Process.send_after(self(), :needs_input_timeout, state.needs_input_timeout_ms)
    %{state | needs_input_timer: timer}
  end

  # Force binary to valid UTF-8 by replacing ALL invalid byte sequences with U+FFFD.
  # Prevents Jason.EncodeError when LiveView sends state diffs over WebSocket.
  defp sanitize_utf8(text) when is_binary(text) do
    do_sanitize_utf8(text, <<>>)
  end

  defp sanitize_utf8(other), do: to_string(other)

  defp do_sanitize_utf8(<<>>, acc), do: acc

  defp do_sanitize_utf8(text, acc) do
    case :unicode.characters_to_binary(text, :utf8) do
      valid when is_binary(valid) ->
        acc <> valid

      {:error, valid, rest} ->
        # Skip one invalid byte and continue
        <<_bad, remaining::binary>> = rest
        do_sanitize_utf8(remaining, acc <> valid <> "\uFFFD")

      {:incomplete, valid, _rest} ->
        acc <> valid <> "\uFFFD"
    end
  end

  defp sanitize_state(state) do
    clean_activity =
      Enum.map(state.activity, fn entry ->
        %{entry | text: sanitize_utf8(Map.get(entry, :text, ""))}
      end)

    %{
      state
      | idle_timer: nil,
        needs_input_timer: nil,
        activity: clean_activity,
        summary: sanitize_utf8(state.summary)
    }
  end

  defp detect_branch(workdir) when is_binary(workdir) do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"],
           cd: workdir,
           stderr_to_stdout: true
         ) do
      {branch, 0} -> String.trim(branch)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp detect_branch(_), do: nil

  defp broadcast_ui_update(state) do
    clean_state = sanitize_state(state)
    IO.puts("[SAM] #{state.session_id} status=#{state.status}")

    Phoenix.PubSub.broadcast(
      Sam.PubSub,
      "sessions:ui",
      {:session_update, state.session_id, clean_state}
    )
  end
end
