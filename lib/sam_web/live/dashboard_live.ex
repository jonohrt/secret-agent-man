defmodule SamWeb.DashboardLive do
  use SamWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")
    end

    sessions = load_sessions()
    selected = List.first(Map.keys(sessions))

    {:ok,
     assign(socket,
       sessions: sessions,
       selected_session: selected,
       show_new_dialog: false,
       show_terminal: false,
       input_text: ""
     )}
  end

  @impl true
  def handle_event("select_session", %{"id" => id}, socket) do
    {:noreply, assign(socket, selected_session: id)}
  end

  def handle_event("toggle_new_dialog", _params, socket) do
    {:noreply, assign(socket, show_new_dialog: !socket.assigns.show_new_dialog)}
  end

  def handle_event("toggle_terminal", _params, socket) do
    {:noreply, assign(socket, show_terminal: !socket.assigns.show_terminal)}
  end

  def handle_event("send_input", %{"input" => text}, socket) do
    if socket.assigns.selected_session && String.trim(text) != "" do
      Sam.Session.Server.send_input(socket.assigns.selected_session, text <> "\n")
    end

    {:noreply, assign(socket, input_text: "")}
  end

  def handle_event("quick_respond", %{"response" => response}, socket) do
    if socket.assigns.selected_session do
      Sam.Session.Server.send_input(socket.assigns.selected_session, response <> "\n")
    end

    {:noreply, socket}
  end

  def handle_event("create_session", params, socket) do
    agent_type =
      try do
        String.to_existing_atom(params["agent_type"])
      rescue
        ArgumentError -> :generic
      end

    workdir = params["workdir"]
    workdir = if workdir == "", do: nil, else: workdir
    prompt = params["prompt"]
    prompt = if prompt == "", do: nil, else: prompt

    command = agent_command(agent_type, workdir, prompt)
    session_id = "session-#{System.unique_integer([:positive])}"

    Sam.Session.GroupSupervisor.start_session(%{
      session_id: session_id,
      name: params["name"] || session_id,
      agent_type: agent_type,
      workdir: workdir,
      command: command
    })

    sessions = load_sessions()

    {:noreply,
     assign(socket,
       sessions: sessions,
       selected_session: session_id,
       show_new_dialog: false
     )}
  end

  @impl true
  def handle_info({:session_update, session_id, state}, socket) do
    sessions = Map.put(socket.assigns.sessions, session_id, state)
    {:noreply, assign(socket, sessions: sessions)}
  end

  # -- Helpers --

  defp load_sessions do
    Sam.Session.Server.list_sessions()
    |> Enum.reduce(%{}, fn id, acc ->
      try do
        Map.put(acc, id, Sam.Session.Server.get_state(id))
      rescue
        _ -> acc
      catch
        :exit, _ -> acc
      end
    end)
  end

  defp agent_command(:claude_code, _workdir, prompt) do
    cmd = ["claude", "--dangerously-skip-permissions"]
    if prompt && prompt != "", do: cmd ++ [prompt], else: cmd
  end

  defp agent_command(:opencode, _, _), do: ["opencode"]
  defp agent_command(:codex, _, prompt), do: ["codex", prompt || ""]
  defp agent_command(:gemini, _, _), do: ["gemini"]
  defp agent_command(:copilot, _, _), do: ["gh", "copilot"]
  defp agent_command(_, _, _), do: ["/bin/bash", "-l"]

  defp selected_state(sessions, selected) do
    if selected, do: Map.get(sessions, selected), else: nil
  end

  defp status_class(nil), do: "idle"
  defp status_class(status), do: Atom.to_string(status)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="dashboard">
      <%!-- Tab Bar --%>
      <div class="tab-bar">
        <%= for {id, state} <- @sessions do %>
          <button
            class={"tab #{if id == @selected_session, do: "active", else: ""}"}
            phx-click="select_session"
            phx-value-id={id}
          >
            <span class={"status-dot #{status_class(state.status)}"}></span>
            <span class="session-name">{state.name}</span>
            <%= if state.branch do %>
              <span class="branch-name">[{state.branch}]</span>
            <% end %>
          </button>
        <% end %>

        <button class="tab-new-btn" phx-click="toggle_new_dialog" title="New Session">+</button>

        <button
          class={"tab-terminal-btn #{if @show_terminal, do: "active", else: ""}"}
          phx-click="toggle_terminal"
        >
          TTY
        </button>
      </div>

      <%!-- Main Content Area --%>
      <div style="flex: 1; position: relative; display: flex; flex-direction: column; overflow: hidden; min-height: 0;">
        <%!-- Terminal Overlay (Task 9) --%>
        <%= if @show_terminal && @selected_session do %>
          <div class="terminal-overlay">
            <div
              id="terminal-container"
              phx-hook="Terminal"
              data-session-id={@selected_session}
            >
            </div>
          </div>
        <% end %>

        <%!-- Dashboard Panels --%>
        <div class="main-panels">
          <%!-- Activity Feed (left, 2/3) --%>
          <div class="activity-panel">
            <div class="panel-header">Activity Feed</div>
            <div class="activity-feed">
              <% state = selected_state(@sessions, @selected_session) %>
              <%= if state && state.activity != [] do %>
                <%= for item <- state.activity do %>
                  <div class="activity-item">
                    <span class="activity-badge">{Map.get(item, :type, "info")}</span>
                    <span class="activity-text">{Map.get(item, :text, inspect(item))}</span>
                  </div>
                <% end %>
              <% else %>
                <div class="activity-empty">
                  <%= if state do %>
                    No activity yet. Waiting for agent output...
                  <% else %>
                    Select or create a session to begin.
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Side Panel (right, 1/3) --%>
          <div class="side-panel">
            <div class="panel-header">Agents</div>
            <div class="agent-list">
              <%= if map_size(@sessions) > 0 do %>
                <%= for {_id, state} <- @sessions do %>
                  <div class="agent-card">
                    <span class={"status-dot #{status_class(state.status)}"}></span>
                    <div>
                      <div class="agent-name">{state.name}</div>
                      <div class="agent-type">{state.agent_type}</div>
                    </div>
                    <span class={"agent-status"} style={"color: var(--status-#{status_class(state.status)});"}>
                      {status_class(state.status)}
                    </span>
                  </div>
                <% end %>
              <% else %>
                <div class="no-sessions-msg">No active agents</div>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Input Bar (shown when selected session needs input) --%>
        <% state = selected_state(@sessions, @selected_session) %>
        <%= if state && state.status == :needs_input do %>
          <div class="input-bar">
            <button class="quick-btn" phx-click="quick_respond" phx-value-response="yes">Yes</button>
            <button class="quick-btn" phx-click="quick_respond" phx-value-response="no">No</button>
            <form phx-submit="send_input" style="display: flex; flex: 1; gap: 8px;">
              <input type="text" name="input" value={@input_text} placeholder="Type a response..." autocomplete="off" />
              <button type="submit" class="send-btn">Send</button>
            </form>
          </div>
        <% end %>
      </div>

      <%!-- New Session Dialog --%>
      <%= if @show_new_dialog do %>
        <div class="dialog-overlay" phx-click="toggle_new_dialog">
          <div class="dialog" phx-click-away="toggle_new_dialog">
            <div class="dialog-header">New Session</div>
            <form phx-submit="create_session">
              <div class="dialog-body">
                <div class="dialog-field">
                  <label>Session Name</label>
                  <input type="text" name="name" placeholder="my-session" />
                </div>
                <div class="dialog-field">
                  <label>Agent Type</label>
                  <select name="agent_type">
                    <option value="claude_code">Claude Code</option>
                    <option value="opencode">OpenCode</option>
                    <option value="codex">Codex</option>
                    <option value="gemini">Gemini</option>
                    <option value="copilot">GitHub Copilot</option>
                    <option value="generic">Shell (bash)</option>
                  </select>
                </div>
                <div class="dialog-field">
                  <label>Working Directory</label>
                  <input type="text" name="workdir" placeholder="/path/to/project" />
                </div>
                <div class="dialog-field">
                  <label>Prompt</label>
                  <textarea name="prompt" placeholder="Optional initial prompt..."></textarea>
                </div>
              </div>
              <div class="dialog-actions">
                <button type="button" class="btn-cancel" phx-click="toggle_new_dialog">Cancel</button>
                <button type="submit" class="btn-create">Create</button>
              </div>
            </form>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
