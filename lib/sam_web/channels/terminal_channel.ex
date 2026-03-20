defmodule SamWeb.TerminalChannel do
  use Phoenix.Channel

  @impl true
  def join("terminal:" <> session_id, _payload, socket) do
    case Registry.lookup(Sam.ProcessRegistry, session_id) do
      [{_pid, _}] ->
        Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")
        # Send a blank input to nudge the PTY into sending a fresh prompt
        send(self(), :request_redraw)
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
  def handle_info(:request_redraw, socket) do
    # Trigger a resize — this forces most terminal programs to redraw their screen
    # Use default size; the client will send the real size momentarily via the resize event
    Sam.Session.Server.resize(socket.assigns.session_id, 80, 24)
    {:noreply, socket}
  end

  def handle_info({:pty_output, _session_id, data}, socket) do
    push(socket, "output", %{data: Base.encode64(data)})
    {:noreply, socket}
  end

  # Ignore other PubSub messages
  def handle_info(_, socket), do: {:noreply, socket}
end
