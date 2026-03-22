defmodule Sam.Session.Summarizer do
  use GenServer
  require Logger

  @default_debounce_ms 5_000
  @decision_point_types [
    :tool_call,
    :tool_result,
    :input_needed,
    :agent_spawn,
    :completion,
    :activity,
    :turn_end,
    :assistant_response
  ]
  @health_check_interval_ms 60_000

  defstruct [:session_id, :debounce_ms, :timer_ref, :ollama_model, :ollama_opts, buffer: []]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def push_event(pid, event) do
    GenServer.cast(pid, {:event, event})
  end

  @impl true
  def init(opts) do
    session_id = Map.fetch!(opts, :session_id)
    Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

    ollama_opts = Map.get(opts, :ollama_opts, [])
    model = detect_ollama(ollama_opts)

    if model do
      Logger.info("[Summarizer] Ollama available: #{model}")
    else
      Logger.info("[Summarizer] Ollama unavailable, using heuristic labels")
      schedule_health_check()
    end

    {:ok,
     %__MODULE__{
       session_id: session_id,
       debounce_ms: Map.get(opts, :debounce_ms, @default_debounce_ms),
       ollama_opts: ollama_opts,
       ollama_model: model
     }}
  end

  # Receive parser events via PubSub
  @impl true
  def handle_info({:parser_event, _session_id, event}, state) do
    handle_cast({:event, event}, state)
  end

  def handle_info(:summarize, state) do
    state = do_summarize(state)
    {:noreply, %{state | timer_ref: nil}}
  end

  # Ignore journal_found — handled by TranscriptWatcher
  def handle_info({:journal_found, _path}, state), do: {:noreply, state}

  def handle_info(:health_check, state) do
    if state.ollama_model == nil do
      case detect_ollama(state.ollama_opts) do
        nil ->
          schedule_health_check()
          {:noreply, state}

        model ->
          Logger.info("[Summarizer] Ollama now available: #{model}")
          {:noreply, %{state | ollama_model: model}}
      end
    else
      {:noreply, state}
    end
  end

  # Ignore other PubSub messages
  def handle_info({:session_update, _, _}, state), do: {:noreply, state}
  def handle_info({:pty_output, _, _}, state), do: {:noreply, state}
  def handle_info({:pty_exit, _, _}, state), do: {:noreply, state}
  def handle_info({:summary, _, _}, state), do: {:noreply, state}

  @impl true
  def handle_cast({:event, event}, state) do
    state = %{state | buffer: state.buffer ++ [event]}

    if event.type in @decision_point_types do
      state = schedule_summary(state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  defp schedule_summary(state) do
    state = cancel_timer(state)
    ref = Process.send_after(self(), :summarize, state.debounce_ms)
    %{state | timer_ref: ref}
  end

  defp do_summarize(%{buffer: []} = state), do: state

  defp do_summarize(state) do
    tool_count =
      Enum.count(state.buffer, &(&1.type == :tool_call))

    {text, source} =
      case state.ollama_model do
        nil ->
          {Sam.LLM.Ollama.heuristic_label(state.buffer), :heuristic}

        model ->
          case Sam.LLM.Ollama.summarize(state.buffer, model, state.ollama_opts) do
            {:ok, summary} -> {summary, :ollama}
            {:error, _} -> {Sam.LLM.Ollama.heuristic_label(state.buffer), :heuristic}
          end
      end

    text = sanitize_text(text)

    Phoenix.PubSub.broadcast(
      Sam.PubSub,
      "session:#{state.session_id}",
      {:summary, state.session_id,
       %{
         text: text,
         source: source,
         tool_count: tool_count,
         timestamp: DateTime.utc_now()
       }}
    )

    %{state | buffer: []}
  end

  defp detect_ollama(opts) do
    case Sam.LLM.Ollama.check_availability(opts) do
      {:ok, model} -> model
      {:error, _} -> nil
    end
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval_ms)
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end

  defp sanitize_text(text) when is_binary(text) do
    text
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
    |> String.replace(~r/\r\n?/, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
    |> ensure_valid_utf8()
  end

  defp sanitize_text(_), do: ""

  defp ensure_valid_utf8(text) do
    if String.valid?(text) do
      text
    else
      text
      |> :unicode.characters_to_binary(:utf8, :utf8)
      |> case do
        {:error, valid, _} -> valid
        {:incomplete, valid, _} -> valid
        valid when is_binary(valid) -> valid
      end
    end
  end
end
