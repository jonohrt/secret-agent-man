defmodule Sam.Session.Summarizer do
  use GenServer
  require Logger

  @default_debounce_ms 5_000
  @decision_point_types [:tool_call, :input_needed, :agent_spawn, :completion, :activity]

  defstruct [:session_id, :debounce_ms, :timer_ref, :jsonl_path, :ollama_opts, buffer: []]

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

    {:ok,
     %__MODULE__{
       session_id: session_id,
       debounce_ms: Map.get(opts, :debounce_ms, @default_debounce_ms),
       ollama_opts: Map.get(opts, :ollama_opts, [])
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

  def handle_info({:journal_found, path}, state) do
    Logger.info("[Summarizer] Received journal path: #{Path.basename(path)}")
    {:noreply, %{state | jsonl_path: path}}
  end

  def handle_info({:session_update, _, _}, state), do: {:noreply, state}

  # Ignore other PubSub messages
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

  defp do_summarize(%{jsonl_path: nil} = state) do
    %{state | buffer: []}
  end

  defp do_summarize(%{buffer: []} = state), do: state

  defp do_summarize(state) do
    turns = Sam.LLM.OllamaClient.extract_turns(state.jsonl_path)

    if turns == [] do
      %{state | buffer: []}
    else
      summary =
        case Sam.LLM.OllamaClient.summarize(turns, state.ollama_opts) do
          {:ok, text} ->
            text

          {:error, _reason} ->
            # Fallback: last assistant message text
            turns
            |> Enum.filter(&(&1.role == "assistant"))
            |> List.last()
            |> case do
              %{content: text} -> String.slice(text, 0, 160)
              nil -> "Agent is working..."
            end
        end

      summary = sanitize_text(summary)

      Phoenix.PubSub.broadcast(
        Sam.PubSub,
        "session:#{state.session_id}",
        {:summary, state.session_id,
         %{
           summary: summary,
           timestamp: DateTime.utc_now()
         }}
      )

      %{state | buffer: []}
    end
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end

  defp sanitize_text(text) when is_binary(text) do
    text
    # strip control chars except \n \r \t
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
    # normalize line endings
    |> String.replace(~r/\r\n?/, "\n")
    # collapse blank lines
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
    |> ensure_valid_utf8()
  end

  defp sanitize_text(_), do: ""

  defp ensure_valid_utf8(text) do
    if String.valid?(text) do
      text
    else
      # Replace invalid bytes with replacement character
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
