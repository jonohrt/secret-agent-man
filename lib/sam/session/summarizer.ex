defmodule Sam.Session.Summarizer do
  use GenServer

  @default_debounce_ms 5_000
  @decision_point_types [:tool_call, :input_needed, :agent_spawn, :completion, :activity]

  defstruct [:session_id, :debounce_ms, :timer_ref, buffer: []]

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

    {:ok, %__MODULE__{
      session_id: session_id,
      debounce_ms: Map.get(opts, :debounce_ms, @default_debounce_ms)
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

  defp do_summarize(%{buffer: []} = state), do: state

  defp do_summarize(state) do
    all_lines =
      state.buffer
      |> Enum.flat_map(fn
        %{type: :activity, lines: lines} -> lines
        %{type: :tool_call, tool: tool, file: file} -> ["Used #{tool} on #{file}"]
        %{type: :input_needed} -> ["Waiting for user input"]
        %{type: :agent_spawn} -> ["Spawned subagent"]
        _ -> []
      end)

    summary = case Sam.LLM.Client.summarize(all_lines) do
      {:ok, text} -> text
      {:error, _} -> Enum.join(all_lines, " | ")
    end

    Phoenix.PubSub.broadcast(Sam.PubSub, "session:#{state.session_id}", {:summary, state.session_id, %{
      summary: summary,
      raw_events: state.buffer,
      timestamp: DateTime.utc_now()
    }})

    %{state | buffer: []}
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state
  defp cancel_timer(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end
end
