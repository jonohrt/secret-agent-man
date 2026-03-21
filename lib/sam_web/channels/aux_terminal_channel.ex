defmodule SamWeb.AuxTerminalChannel do
  use Phoenix.Channel
  require Logger

  @impl true
  def join("aux_terminal:" <> session_id, %{"workdir" => workdir}, socket) do
    shell = System.get_env("SHELL") || "/bin/zsh"

    {:ok, pty_pid} =
      Sam.Session.PTY.start_link(%{
        session_id: "aux-#{session_id}",
        command: [shell],
        workdir: workdir
      })

    Process.link(pty_pid)
    Phoenix.PubSub.subscribe(Sam.PubSub, "session:aux-#{session_id}")

    {:ok, assign(socket, pty_pid: pty_pid, session_id: session_id)}
  end

  @impl true
  def handle_in("input", %{"data" => data}, socket) do
    Sam.Session.PTY.send_input(socket.assigns.pty_pid, data)
    {:noreply, socket}
  end

  @impl true
  def handle_in("resize", %{"cols" => cols, "rows" => rows}, socket) do
    Sam.Session.PTY.resize(socket.assigns.pty_pid, cols, rows)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:pty_output, _session_id, data}, socket) do
    push(socket, "output", %{data: Base.encode64(data)})
    {:noreply, socket}
  end

  def handle_info({:pty_exit, _session_id, _code}, socket) do
    {:stop, :normal, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if pid = socket.assigns[:pty_pid] do
      try do
        Sam.Session.PTY.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end
  end
end
