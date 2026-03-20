defmodule Sam.Session.Parser do
  use GenServer

  defstruct [:session_id, :quiescence_ms, :timer_ref, buffer: []]

  @default_quiescence_ms 3_000
  @ansi_regex ~r/\e\[[0-9;]*[a-zA-Z]|\e\].*?(?:\e\\|\x07)|\e[()][AB012]|\e[>=<]|\e\[[\?]?[0-9;]*[hlm]/

  # Known hook event types — pre-create atoms to allow String.to_existing_atom
  @known_event_types ~w(tool_call tool_result session_start session_end pre_tool_call post_tool_call)a
  def __known_event_types__, do: @known_event_types

  ## Public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def push_output(pid, data) when is_binary(data) do
    GenServer.cast(pid, {:output, data})
  end

  def push_hook_event(pid, event) when is_map(event) do
    GenServer.cast(pid, {:hook_event, event})
  end

  ## Pure functions

  def strip_ansi(text) do
    Regex.replace(@ansi_regex, text, "")
  end

  def input_needed?(text) do
    stripped = strip_ansi(text)

    patterns = [
      ~r/\?\s+Allow/i,
      ~r/\[y\/N\]/i,
      ~r/\[Y\/n\]/i,
      ~r/\(y\/N\)/i,
      ~r/\(Y\/n\)/i,
      ~r/[Pp]ress enter/i,
      ~r/[Cc]ontinue\?/,
      ~r/[Pp]roceed\?/
    ]

    Enum.any?(patterns, &Regex.match?(&1, stripped))
  end

  def parse_hook_event(event) do
    type =
      try do
        String.to_existing_atom(event["event"])
      rescue
        ArgumentError -> String.to_atom(event["event"])
      end

    %{
      type: type,
      tool: event["tool"],
      file: event["file"],
      session_id: event["session_id"],
      timestamp: DateTime.utc_now()
    }
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    session_id = Map.fetch!(opts, :session_id)
    Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

    {:ok,
     %__MODULE__{
       session_id: session_id,
       quiescence_ms: Map.get(opts, :quiescence_ms, @default_quiescence_ms)
     }}
  end

  @impl true
  def handle_cast({:output, data}, state) do
    stripped = strip_ansi(data)
    lines = stripped |> String.split("\n", trim: true)

    if input_needed?(data) do
      Phoenix.PubSub.broadcast(
        Sam.PubSub,
        "session:#{state.session_id}",
        {:parser_event, state.session_id, %{type: :input_needed}}
      )
    end

    state = cancel_timer(state)
    timer_ref = Process.send_after(self(), :quiescence, state.quiescence_ms)

    {:noreply, %{state | buffer: state.buffer ++ lines, timer_ref: timer_ref}}
  end

  @impl true
  def handle_cast({:hook_event, event}, state) do
    parsed = parse_hook_event(event)

    Phoenix.PubSub.broadcast(
      Sam.PubSub,
      "session:#{state.session_id}",
      {:parser_event, state.session_id, parsed}
    )

    state = flush_buffer(state)
    {:noreply, state}
  end

  # Receive PTY output via PubSub
  @impl true
  def handle_info({:pty_output, _session_id, data}, state) do
    handle_cast({:output, data}, state)
  end

  def handle_info(:quiescence, state) do
    state = flush_buffer(state)
    {:noreply, %{state | timer_ref: nil}}
  end

  # Ignore other PubSub messages
  def handle_info({:pty_exit, _, _}, state), do: {:noreply, state}
  def handle_info({:parser_event, _, _}, state), do: {:noreply, state}
  def handle_info({:summary, _, _}, state), do: {:noreply, state}

  ## Private helpers

  defp flush_buffer(%{buffer: []} = state), do: state

  defp flush_buffer(state) do
    Phoenix.PubSub.broadcast(
      Sam.PubSub,
      "session:#{state.session_id}",
      {:parser_event, state.session_id,
       %{
         type: :activity,
         lines: state.buffer,
         timestamp: DateTime.utc_now()
       }}
    )

    %{state | buffer: []}
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end
end
