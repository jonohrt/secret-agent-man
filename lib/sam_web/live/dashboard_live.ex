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
       input_text: "",
       tick: 0
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

  def handle_event("kill_all", _params, socket) do
    for session_id <- Sam.Session.Server.list_sessions() do
      Sam.Session.GroupSupervisor.terminate_session(session_id)
    end

    {:noreply, assign(socket, sessions: %{}, selected_session: nil)}
  end

  def handle_event("kill_session", %{"id" => session_id}, socket) do
    Sam.Session.GroupSupervisor.terminate_session(session_id)

    sessions = load_sessions()

    selected =
      if socket.assigns.selected_session == session_id,
        do: List.first(Map.keys(sessions)),
        else: socket.assigns.selected_session

    {:noreply, assign(socket, sessions: sessions, selected_session: selected)}
  end

  def handle_event("create_session", params, socket) do
    agent_type =
      try do
        String.to_existing_atom(params["agent_type"])
      rescue
        ArgumentError -> :generic
      end

    workdir = params["workdir"]

    workdir =
      if workdir == "" or is_nil(workdir) do
        case File.cwd() do
          {:ok, cwd} -> cwd
          {:error, _} -> "."
        end
      else
        workdir
      end

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
  def handle_info({:session_update, session_id, new_state}, socket) do
    session_map = %{
      session_id: new_state.session_id,
      name: new_state.name,
      status: new_state.status,
      agent_type: new_state.agent_type,
      branch: new_state.branch,
      workdir: new_state.workdir,
      activity: new_state.activity,
      agents: new_state.agents
    }

    sessions = Map.put(socket.assigns.sessions, session_id, session_map)
    # Bump a counter to force LiveView to re-diff the template
    tick = Map.get(socket.assigns, :tick, 0) + 1
    {:noreply, assign(socket, sessions: sessions, tick: tick)}
  end

  # -- Helpers --

  defp load_sessions do
    Sam.Session.Server.list_sessions()
    |> Enum.reduce(%{}, fn id, acc ->
      try do
        state = Sam.Session.Server.get_state(id)

        session_map = %{
          session_id: state.session_id,
          name: state.name,
          status: state.status,
          agent_type: state.agent_type,
          branch: state.branch,
          workdir: state.workdir,
          activity: state.activity,
          agents: state.agents
        }

        Map.put(acc, id, session_map)
      rescue
        _ -> acc
      catch
        :exit, _ -> acc
      end
    end)
  end

  defp agent_command(agent_type, workdir, prompt) do
    adapter = agent_adapter(agent_type)
    adapter.spawn_command(workdir, prompt)
  end

  defp agent_adapter(:claude_code), do: Sam.Agents.ClaudeCode
  defp agent_adapter(:mock), do: Sam.Agents.Mock
  defp agent_adapter(_), do: Sam.Agents.Generic

  defp selected_state(sessions, selected) do
    if selected, do: Map.get(sessions, selected), else: nil
  end

  defp active_agent_count(nil), do: 1

  defp active_agent_count(state) do
    subagent_count = state |> Map.get(:agents, []) |> Enum.count(&(&1.status == :working))
    1 + subagent_count
  end

  defp status_class(nil), do: "idle"
  defp status_class(status), do: Atom.to_string(status)

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(_), do: ""

  defp format_uptime(%{started_at: started_at}) when not is_nil(started_at) do
    diff = DateTime.diff(DateTime.utc_now(), started_at)
    hours = div(diff, 3600)
    minutes = diff |> rem(3600) |> div(60)
    seconds = rem(diff, 60)

    "#{String.pad_leading(to_string(hours), 2, "0")}:#{String.pad_leading(to_string(minutes), 2, "0")}:#{String.pad_leading(to_string(seconds), 2, "0")}"
  end

  defp format_uptime(_), do: "00:00:00"

  defp agent_activity_text(%{activity: [latest | _]}), do: sanitize_text(latest.text)

  defp agent_activity_text(%{summary: summary}) when is_binary(summary) and summary != "",
    do: sanitize_text(summary)

  defp agent_activity_text(_), do: "Awaiting directives"

  defp activity_msg_class(%{type: :system}), do: "system"
  defp activity_msg_class(%{type: :agent_event}), do: "agent-event"
  defp activity_msg_class(_), do: ""

  # Strip terminal control chars and block drawing chars from raw PTY summary output.
  # Ensures valid UTF-8 first to prevent crashes in String.replace.
  defp sanitize_text(text) when is_binary(text) do
    text
    |> ensure_valid_utf8()
    |> String.replace(~r/[\x00-\x1F\x7F]/u, "")
    |> String.replace(~r/[▐▛▜▌▝▘▞▚▙▟▗▖▊▋▍▎▏█▓▒░⏵⏴◐◑]/u, "")
    |> String.trim()
    |> case do
      "" -> "Processing..."
      s -> String.slice(s, 0, 80)
    end
  end

  defp sanitize_text(_), do: "Processing..."

  defp ensure_valid_utf8(text) do
    if String.valid?(text), do: text, else: do_ensure_valid_utf8(text, <<>>)
  end

  defp do_ensure_valid_utf8(<<>>, acc), do: acc

  defp do_ensure_valid_utf8(text, acc) do
    case :unicode.characters_to_binary(text, :utf8) do
      valid when is_binary(valid) -> acc <> valid
      {:error, valid, <<_bad, rest::binary>>} -> do_ensure_valid_utf8(rest, acc <> valid)
      {:incomplete, valid, _rest} -> acc <> valid
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="sam-shell">
      <%!-- TOP NAV --%>
      <nav class="sam-topnav">
        <div class="sam-logo">
          <svg
            viewBox="0 0 28 28"
            width="24"
            height="24"
            fill="none"
            xmlns="http://www.w3.org/2000/svg"
          >
            <circle cx="14" cy="14" r="12" stroke="#afc9ea" stroke-width="0.8" opacity="0.3" />
            <line x1="14" y1="2" x2="14" y2="7" stroke="#afc9ea" stroke-width="0.8" opacity="0.4" />
            <line x1="14" y1="21" x2="14" y2="26" stroke="#afc9ea" stroke-width="0.8" opacity="0.4" />
            <line x1="2" y1="14" x2="7" y2="14" stroke="#afc9ea" stroke-width="0.8" opacity="0.4" />
            <line x1="21" y1="14" x2="26" y2="14" stroke="#afc9ea" stroke-width="0.8" opacity="0.4" />
            <circle cx="14" cy="14" r="6" stroke="#22c55e" stroke-width="1.2" opacity="0.7" />
            <circle cx="14" cy="12" r="2.5" fill="#afc9ea" opacity="0.85" />
            <path d="M10 19.5 C10 16.5 18 16.5 18 19.5" fill="#afc9ea" opacity="0.6" />
            <path
              d="M10.5 12 L17.5 12 L16.5 10.5 Q14 9 11.5 10.5 Z"
              fill="#132030"
              stroke="#afc9ea"
              stroke-width="0.4"
              opacity="0.85"
            />
          </svg>
          <div class="sam-logo-text">
            <div class="sam-logo-main">
              Secret Agent Man<span class="paren">(</span><span class="ager">ager</span><span class="paren">)</span>
            </div>
            <div class="sam-logo-sub">TACTICAL AGENT COMMAND</div>
          </div>
        </div>
        <div class="sam-topnav-actions">
          <button class="sam-topnav-btn">
            <svg
              width="14"
              height="14"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.8"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <circle cx="12" cy="12" r="3" /><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
            </svg>
            SETTINGS
          </button>
          <button class="sam-topnav-btn danger" phx-click="kill_all">
            <svg
              width="14"
              height="14"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="1.8"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <circle cx="12" cy="12" r="10" /><circle cx="12" cy="12" r="6" /><circle
                cx="12"
                cy="12"
                r="2"
              />
              <line x1="12" y1="2" x2="12" y2="6" /><line x1="12" y1="18" x2="12" y2="22" />
              <line x1="2" y1="12" x2="6" y2="12" /><line x1="18" y1="12" x2="22" y2="12" />
            </svg>
            KILL ALL
          </button>
        </div>
      </nav>

      <%!-- TAB BAR --%>
      <div class="sam-tabs">
        <div
          :for={{id, state} <- @sessions}
          class={"sam-tab #{if id == @selected_session, do: "active"}"}
          phx-click="select_session"
          phx-value-id={id}
        >
          <span class={"status-dot #{status_class(state.status)}"}></span>
          {state.name || id}
        </div>
        <div class="sam-tab-actions">
          <button class="sam-btn-deploy" phx-click="toggle_new_dialog">+ DEPLOY AGENT</button>
        </div>
      </div>

      <%!-- STATUS BAR --%>
      <%= if @selected_session do %>
        <% state = selected_state(@sessions, @selected_session) %>
        <%= if state do %>
          <div class="sam-status-bar">
            <div class="sam-status-left">
              <span class="sam-session-name">{state.name || @selected_session}</span>
              <div class="sam-status-badge">
                <span class={"status-dot #{status_class(state.status)}"}></span>
                {state.status |> to_string() |> String.upcase()}
              </div>
              <span class="sam-status-meta">
                {Map.get(state, :workdir) || "~"} &bull; {Map.get(state, :branch) || "no branch"} &bull; {format_uptime(
                  state
                )}
              </span>
            </div>
            <div class="sam-status-actions">
              <%= if state.status == :needs_input do %>
                <form phx-submit="send_input" class="sam-input-inline">
                  <input
                    type="text"
                    name="input"
                    value={@input_text}
                    placeholder="Enter response..."
                    autofocus
                  />
                  <button
                    type="button"
                    class="sam-quick-btn"
                    phx-click="quick_respond"
                    phx-value-response="yes"
                  >
                    YES
                  </button>
                  <button
                    type="button"
                    class="sam-quick-btn"
                    phx-click="quick_respond"
                    phx-value-response="no"
                  >
                    NO
                  </button>
                  <button type="submit" class="sam-btn-outline">SEND</button>
                </form>
              <% else %>
                <button class="sam-btn-outline" phx-click="toggle_terminal">
                  {if @show_terminal, do: "HIDE TTY", else: "SHOW TTY"}
                </button>
                <button
                  class="sam-btn-outline danger"
                  phx-click="kill_session"
                  phx-value-id={@selected_session}
                >
                  TERMINATE
                </button>
              <% end %>
            </div>
          </div>
        <% end %>
      <% end %>

      <%!-- BENTO GRID --%>
      <div class="sam-bento">
        <%!-- TERMINAL (8 cols, spans 2 rows) --%>
        <div class="sam-panel sam-terminal">
          <div class="sam-terminal-indicator">
            <span class="live-dot"></span> VIEWING: main <span class="live-label">&#9654; LIVE</span>
          </div>
          <%= if @selected_session do %>
            <div
              class="sam-terminal-body"
              id={"terminal-#{@selected_session}"}
              phx-hook="Terminal"
              phx-update="ignore"
              data-session-id={@selected_session}
            >
            </div>
          <% else %>
            <div
              class="sam-terminal-body"
              style="display: flex; align-items: center; justify-content: center;"
            >
              <span style="color: var(--outline); font-family: var(--font-mono);">
                No session selected
              </span>
            </div>
          <% end %>
        </div>

        <%!-- ACTIVITY FEED (4 cols, top right) --%>
        <div class="sam-panel">
          <div class="sam-panel-header">
            <span>ACTIVITY FEED</span>
            <span style="opacity: 0.5;">LIVE</span>
          </div>
          <div class="sam-panel-body">
            <%= if @selected_session do %>
              <% state = selected_state(@sessions, @selected_session) %>
              <%= if state do %>
                <div
                  :for={item <- Enum.take(Map.get(state, :activity, []), 50)}
                  class="activity-item"
                >
                  <span class="time">{format_time(item.timestamp)}</span>
                  <span class={"msg #{activity_msg_class(item)}"}>{sanitize_text(item.text)}</span>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>

        <%!-- AGENTS PANEL (4 cols, bottom right) --%>
        <div class="sam-panel">
          <div class="sam-panel-header">
            <span>AGENTS</span>
            <span style="opacity: 0.5;">
              {active_agent_count(selected_state(@sessions, @selected_session))} ACTIVE
            </span>
          </div>
          <div class="sam-panel-body">
            <%= if @selected_session do %>
              <% state = selected_state(@sessions, @selected_session) %>
              <%= if state do %>
                <div class="agent-row selected">
                  <div class="agent-row-top">
                    <span class={"status-dot #{status_class(state.status)}"}></span>
                    <span class="agent-name">main</span>
                    <span class="agent-badge">PRIMARY</span>
                    <span class={"agent-status #{status_class(state.status)}"}>
                      {state.status |> to_string() |> String.upcase()}
                    </span>
                  </div>
                  <div class="agent-activity">
                    {agent_activity_text(state)}
                  </div>
                </div>
                <%= for agent <- Map.get(state, :agents, []) do %>
                  <div class="agent-row">
                    <div class="agent-row-top">
                      <span class={"status-dot #{status_class(agent.status)}"}></span>
                      <span class="agent-name">{agent.description}</span>
                      <span class={"agent-status #{status_class(agent.status)}"}>
                        {agent.status |> to_string() |> String.upcase()}
                      </span>
                    </div>
                  </div>
                <% end %>
              <% end %>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- FOOTER --%>
      <footer class="sam-footer">
        <span>
          <span class="sam-footer-dot" style="background: var(--phosphor-green);"></span>
          {map_size(@sessions)} SESSIONS &bull; THEME: COMMAND
        </span>
        <span></span>
      </footer>

      <%!-- SESSION CREATION MODAL --%>
      <%= if @show_new_dialog do %>
        <div class="modal-overlay">
          <section class="modal-panel" phx-click-away="toggle_new_dialog">
            <div class="modal-grid-bg"></div>
            <div class="modal-scan"></div>
            <div class="modal-content">
              <div class="modal-header">
                <span class="modal-classified">CLASSIFIED</span>
                <span class="modal-divider"></span>
                <span class="modal-ref">REF: SC-{DateTime.utc_now().year}-XP</span>
              </div>
              <h1 class="modal-title">New Operation</h1>

              <form phx-submit="create_session">
                <div class="modal-field">
                  <label class="modal-label">SESSION_IDENTITY</label>
                  <input
                    class="modal-input"
                    type="text"
                    name="name"
                    placeholder="ENTER OPERATION CODENAME..."
                    required
                  />
                </div>

                <div class="modal-input-row">
                  <div class="modal-field">
                    <label class="modal-label">AGENT_SPECIFICATION</label>
                    <select class="modal-select" name="agent_type">
                      <option value="claude_code">CLAUDE_CODE</option>
                    </select>
                  </div>
                  <div class="modal-field">
                    <label class="modal-label">DEPLOYMENT_VECTOR</label>
                    <input
                      class="modal-input"
                      type="text"
                      name="workdir"
                      placeholder="/ROOT/PROJECTS/..."
                      style="font-family: var(--font-mono); font-size: 10px;"
                    />
                  </div>
                </div>

                <div class="modal-field">
                  <label class="modal-label">INITIAL_DIRECTIVES</label>
                  <textarea
                    class="modal-textarea"
                    name="prompt"
                    rows="3"
                    placeholder="DESCRIBE THE TARGET ARCHITECTURE AND OBJECTIVES..."
                  ></textarea>
                </div>

                <div class="modal-footer">
                  <button type="button" class="modal-abort" phx-click="toggle_new_dialog">
                    &#10005; ABORT_MISSION
                  </button>
                  <div style="display: flex; align-items: center; gap: 12px;">
                    <div class="modal-auth">
                      AUTHORIZATION_REQUIRED<br />
                      <span style="color: rgba(175,201,234,0.5);">LVL_07_ACCESS_GRANTED</span>
                    </div>
                    <button type="submit" class="modal-submit">
                      &#9656; INITIATE OPERATION
                    </button>
                  </div>
                </div>
              </form>
            </div>
          </section>
        </div>
      <% end %>
    </div>
    """
  end
end
