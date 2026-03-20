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
      |> Enum.map(&sanitize_text/1)
      |> Enum.filter(fn line ->
        # Drop lines that are just whitespace, single chars, or terminal noise
        trimmed = String.trim(line)
        String.length(trimmed) > 3 and not String.match?(trimmed, ~r/^[\s│|─┌┐└┘├┤┬┴┼╭╮╰╯═║╔╗╚╝╠╣╦╩╬\-\+\*]+$/)
      end)
      |> Enum.uniq()

    if all_lines == [] do
      # Nothing meaningful to summarize
      state
    else
      summary = case Sam.LLM.Client.summarize(all_lines) do
        {:ok, text} -> text
        {:error, _} -> Enum.join(all_lines, " | ")
      end

      summary = sanitize_text(summary)

      Phoenix.PubSub.broadcast(Sam.PubSub, "session:#{state.session_id}", {:summary, state.session_id, %{
        summary: summary,
        raw_events: state.buffer,
        timestamp: DateTime.utc_now()
      }})

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
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")  # strip control chars except \n \r \t
    |> String.replace(~r/\r\n?/, "\n")                               # normalize line endings
    |> String.replace(~r/\n{3,}/, "\n\n")                            # collapse blank lines
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
