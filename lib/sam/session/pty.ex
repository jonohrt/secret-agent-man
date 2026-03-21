defmodule Sam.Session.PTY do
  use GenServer
  require Logger

  defstruct [:port, :session_id, :workdir]

  defp pty_port_path, do: Path.join(:code.priv_dir(:sam), "native/pty_port")

  ## Public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def send_input(pid, data) when is_binary(data) do
    GenServer.cast(pid, {:input, data})
  end

  def resize(pid, cols, rows) do
    GenServer.cast(pid, {:resize, cols, rows})
  end

  def stop(pid) do
    GenServer.cast(pid, {:control, "kill"})
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    command = Map.fetch!(opts, :command)
    session_id = Map.fetch!(opts, :session_id)
    workdir = Map.get(opts, :workdir)
    rows = Map.get(opts, :rows, 24)
    cols = Map.get(opts, :cols, 80)

    # Subscribe to input commands from Session.Server
    Phoenix.PubSub.subscribe(Sam.PubSub, "session_input:#{session_id}")

    port =
      Port.open({:spawn_executable, pty_port_path()}, [
        :binary,
        :exit_status,
        {:packet, 4}
      ])

    port_number =
      Application.get_env(:sam, SamWeb.Endpoint)[:http][:port] || 4000

    spawn_msg =
      Jason.encode!(%{
        cmd: "spawn",
        args: command,
        rows: rows,
        cols: cols,
        workdir: workdir,
        env: %{
          "SAM_SESSION_ID" => session_id,
          "SAM_PORT" => to_string(port_number)
        }
      })

    Port.command(port, spawn_msg)

    {:ok,
     %__MODULE__{
       port: port,
       session_id: session_id,
       workdir: workdir
     }}
  end

  # Cast handlers for direct PID-based calls
  @impl true
  def handle_cast({:input, data}, state) do
    Port.command(state.port, data)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:resize, cols, rows}, state) do
    msg = Jason.encode!(%{cmd: "resize", rows: rows, cols: cols})
    Port.command(state.port, msg)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:control, cmd}, state) do
    msg = Jason.encode!(%{cmd: cmd})
    Port.command(state.port, msg)
    {:noreply, state}
  end

  # PubSub handlers for input from Session.Server
  @impl true
  def handle_info({:input, data}, state) do
    Port.command(state.port, data)
    {:noreply, state}
  end

  @impl true
  def handle_info({:resize, cols, rows}, state) do
    msg = Jason.encode!(%{cmd: "resize", rows: rows, cols: cols})
    Port.command(state.port, msg)
    {:noreply, state}
  end

  @impl true
  def handle_info(:kill, state) do
    msg = Jason.encode!(%{cmd: "kill"})
    Port.command(state.port, msg)
    {:noreply, state}
  end

  # Port data handlers
  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case Jason.decode(data) do
      {:ok, %{"event" => "started"}} ->
        Logger.debug("PTY started for session #{state.session_id}")
        {:noreply, state}

      {:ok, %{"event" => "exit", "code" => code}} ->
        Phoenix.PubSub.broadcast(
          Sam.PubSub,
          "session:#{state.session_id}",
          {:pty_exit, state.session_id, code}
        )

        {:stop, :normal, state}

      {:ok, %{"event" => "error", "msg" => msg}} ->
        Logger.error("PTY error for session #{state.session_id}: #{msg}")
        {:stop, {:error, msg}, state}

      _ ->
        # Raw PTY output → broadcast
        Phoenix.PubSub.broadcast(
          Sam.PubSub,
          "session:#{state.session_id}",
          {:pty_output, state.session_id, data}
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Phoenix.PubSub.broadcast(
      Sam.PubSub,
      "session:#{state.session_id}",
      {:pty_exit, state.session_id, status}
    )

    {:stop, :normal, state}
  end
end
