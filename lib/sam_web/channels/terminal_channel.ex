defmodule SamWeb.TerminalChannel do
  use Phoenix.Channel

  @impl true
  def join("terminal:" <> session_id, _payload, socket) do
    case Registry.lookup(Sam.ProcessRegistry, session_id) do
      [{_pid, _}] ->
        Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")
        {:ok, assign(socket, session_id: session_id)}

      [] ->
        {:error, %{reason: "session not found"}}
    end
  end

  @impl true
  def handle_in("input", %{"data" => data}, socket) do
    Sam.Session.Server.send_input(socket.assigns.session_id, data)
    {:noreply, socket}
  end

  @impl true
  def handle_in("resize", %{"cols" => cols, "rows" => rows}, socket) do
    Sam.Session.Server.resize(socket.assigns.session_id, cols, rows)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:pty_output, _session_id, data}, socket) do
    push(socket, "output", %{data: Base.encode64(data)})
    {:noreply, socket}
  end

  # Ignore other PubSub messages
  @impl true
  def handle_info(_, socket), do: {:noreply, socket}
end
