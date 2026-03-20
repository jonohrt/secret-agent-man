defmodule Sam.Session.Server do
  use GenServer
  require Logger

  @idle_timeout_ms 1_000

  defstruct [
    :session_id, :name, :agent_type, :branch, :workdir, :idle_timer,
    status: :starting,
    activity: [],
    agents: []
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

  def push_hook_event(session_id, event) do
    GenServer.cast(via(session_id), {:hook_event, event})
  end

  def stop(session_id) do
    GenServer.cast(via(session_id), :stop)
  end

  def list_sessions do
    Registry.select(Sam.ProcessRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  defp via(session_id), do: {:via, Registry, {Sam.ProcessRegistry, session_id}}

  ## GenServer callbacks

  @impl true
  def init(opts) do
    session_id = Map.fetch!(opts, :session_id)
    Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

    state = %__MODULE__{
      session_id: session_id,
      name: Map.get(opts, :name, session_id),
      agent_type: Map.get(opts, :agent_type, :generic),
      workdir: Map.get(opts, :workdir),
      status: :running
    }

    broadcast_ui_update(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:send_input, data}, state) do
    Phoenix.PubSub.broadcast(Sam.PubSub, "session_input:#{state.session_id}", {:input, data})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:resize, cols, rows}, state) do
    Phoenix.PubSub.broadcast(Sam.PubSub, "session_input:#{state.session_id}", {:resize, cols, rows})
    {:noreply, state}
  end

  @impl true
  def handle_cast(:stop, state) do
    Phoenix.PubSub.broadcast(Sam.PubSub, "session_input:#{state.session_id}", :kill)
    {:stop, :normal, state}
  end

  @impl true
  def handle_cast({:hook_event, event}, state) do
    Phoenix.PubSub.broadcast(Sam.PubSub, "session:#{state.session_id}",
      {:parser_event, state.session_id, Sam.Session.Parser.parse_hook_event(event)})
    {:noreply, state}
  end

  ## PubSub event handlers

  @impl true
  def handle_info({:parser_event, _session_id, %{type: :input_needed}}, state) do
    state = cancel_idle_timer(state)
    state = %{state | status: :needs_input}
    broadcast_ui_update(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:parser_event, _, %{type: :activity}}, state) do
    # Parser flushed an activity batch — agent was producing real output
    state = cancel_idle_timer(state)
    timer = Process.send_after(self(), :idle_timeout, @idle_timeout_ms)

    if state.status != :working do
      state = %{state | status: :working, idle_timer: timer}
      broadcast_ui_update(state)
      {:noreply, state}
    else
      {:noreply, %{state | idle_timer: timer}}
    end
  end

  @impl true
  def handle_info({:parser_event, _, _}, state), do: {:noreply, state}

  @impl true
  def handle_info({:summary, _session_id, summary}, state) do
    entry = %{
      type: :summary,
      text: summary.summary,
      timestamp: summary.timestamp
    }
    activity = [entry | state.activity] |> Enum.take(100)
    state = %{state | activity: activity}
    broadcast_ui_update(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:pty_output, _, _}, state), do: {:noreply, state}

  @impl true
  def handle_info(:idle_timeout, state) do
    # No output for @idle_timeout_ms — transition to idle
    if state.status == :working do
      state = %{state | status: :idle, idle_timer: nil}
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

  ## Private helpers

  defp cancel_idle_timer(%{idle_timer: nil} = state), do: state
  defp cancel_idle_timer(%{idle_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | idle_timer: nil}
  end

  defp broadcast_ui_update(state) do
    # Don't include the timer ref in the broadcast — it's not serializable
    clean_state = %{state | idle_timer: nil}
    IO.puts("[SAM] #{state.session_id} status=#{state.status}")
    Phoenix.PubSub.broadcast(Sam.PubSub, "sessions:ui", {:session_update, state.session_id, clean_state})
  end
end
