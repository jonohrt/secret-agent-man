defmodule SamWeb.Components.TerminalModal do
  use Phoenix.LiveComponent

  @impl true
  def render(assigns) do
    ~H"""
    <div class={"terminal-modal-overlay #{unless @visible, do: "hidden"}"}>
      <div class="terminal-modal">
        <div class="terminal-modal-header">
          <span class="terminal-modal-title">
            <span class="live-dot"></span> TERMINAL: {@session_name}
          </span>
          <button class="terminal-modal-close" phx-click="toggle_terminal_modal">✕</button>
        </div>
        <div
          class="terminal-modal-body"
          id={"aux-terminal-#{@session_id}"}
          phx-hook="AuxTerminal"
          phx-update="ignore"
          data-session-id={@session_id}
          data-workdir={@workdir}
        >
        </div>
      </div>
    </div>
    """
  end
end
