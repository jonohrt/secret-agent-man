defmodule Sam.Session.Server do
  use GenServer
  require Logger

  defstruct [
    :session_id, :name, :agent_type, :branch, :workdir,
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

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:send_input, data}, state) do
    Phoenix.PubSub.broadcast(Sam.PubSub, "session_input:#{state.session_id}", {:input, data})
    {:noreply, %{state | status: :running}}
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
    state = %{state | status: :needs_input}
    broadcast_ui_update(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:parser_event, _, _}, state), do: {:noreply, state}

  @impl true
  def handle_info({:summary, _session_id, summary}, state) do
    activity = [summary | state.activity] |> Enum.take(100)
    state = %{state | activity: activity}
    broadcast_ui_update(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:pty_output, _, _}, state), do: {:noreply, state}

  @impl true
  def handle_info({:pty_exit, _session_id, 0}, state) do
    state = %{state | status: :done}
    broadcast_ui_update(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:pty_exit, _session_id, _code}, state) do
    state = %{state | status: :error}
    broadcast_ui_update(state)
    {:noreply, state}
  end

  defp broadcast_ui_update(state) do
    Phoenix.PubSub.broadcast(Sam.PubSub, "sessions:ui", {:session_update, state.session_id, state})
  end
end
