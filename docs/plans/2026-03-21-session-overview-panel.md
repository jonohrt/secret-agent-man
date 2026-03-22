# Session Overview Panel Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a "SESSIONS" tab alongside "ACTIVITY" in the right-side panel, showing all sessions at a glance with name, time, and summary.

**Architecture:** Add a `panel_view` assign to DashboardLive that toggles between `:activity` and `:sessions`. The panel header renders two tabs, clicking switches the assign. Session overview iterates `@sessions` rendering compact two-line cards. No new data sources needed — everything comes from existing `@sessions` assign.

**Tech Stack:** Phoenix LiveView (Elixir), CSS

---

### Task 1: Add panel_view assign and event handler

**Files:**
- Modify: `lib/sam_web/live/dashboard_live.ex`

**Step 1: Add assign in mount/3**

In the `assign()` call inside `mount/3` (around line 50-63), add `panel_view: :activity` to the assigns list:

```elixir
      |> assign(
        sessions: sessions,
        session_ids: session_ids,
        selected_session: selected,
        show_new_dialog: false,
        show_terminal_modal: false,
        input_text: "",
        tick: 0,
        default_workdir: Sam.Settings.get(:default_workdir, File.cwd!()),
        mru_workdirs: Sam.Settings.get(:mru_workdirs, []),
        show_settings: false,
        summarizer_mode: detect_summarizer_mode(),
        current_uptime: "00:00:00",
        panel_view: :activity
      )
```

**Step 2: Add event handler**

Add a new `handle_event` clause after the existing `toggle_settings` handler (around line 183):

```elixir
  def handle_event("set_panel_view", %{"view" => view}, socket) do
    panel_view = String.to_existing_atom(view)
    {:noreply, assign(socket, panel_view: panel_view)}
  end
```

**Step 3: Run tests**

Run: `mix test test/sam/session/server_test.exs`
Expected: PASS (no test changes needed — this is additive)

**Step 4: Commit**

```bash
git add lib/sam_web/live/dashboard_live.ex
git commit -m "feat: add panel_view assign and set_panel_view event handler"
```

---

### Task 2: Update panel header with tabs

**Files:**
- Modify: `lib/sam_web/live/dashboard_live.ex` (render function, around line 623-627)

**Step 1: Replace the activity feed panel header**

Find this block in the render function (the ACTIVITY FEED panel header):

```heex
        <div class="sam-panel-header">
          <span>ACTIVITY FEED</span>
          <span style="opacity: 0.5;">LIVE</span>
        </div>
```

Replace with:

```heex
        <div class="sam-panel-header panel-tabs">
          <button
            class={"panel-tab #{if @panel_view == :activity, do: "active"}"}
            phx-click="set_panel_view"
            phx-value-view="activity"
          >
            ACTIVITY
          </button>
          <button
            class={"panel-tab #{if @panel_view == :sessions, do: "active"}"}
            phx-click="set_panel_view"
            phx-value-view="sessions"
          >
            SESSIONS
          </button>
          <span style="flex:1;"></span>
          <span style="opacity: 0.5;">LIVE</span>
        </div>
```

**Step 2: Commit**

```bash
git add lib/sam_web/live/dashboard_live.ex
git commit -m "feat: add panel tab switcher to activity feed header"
```

---

### Task 3: Add CSS for panel tabs

**Files:**
- Modify: `assets/css/app.css`

**Step 1: Add panel tab styles**

Add after the `.sam-panel-body` block (around line 481), before the TERMINAL PANEL section:

```css
/* Panel header tabs */
.panel-tabs {
  gap: 0;
  padding: 0 12px;
}

.panel-tab {
  background: none;
  border: none;
  border-bottom: 2px solid transparent;
  padding: 8px 12px;
  font-family: var(--font-headline);
  font-size: 0.75rem;
  font-weight: 700;
  letter-spacing: 0.15em;
  text-transform: uppercase;
  color: var(--outline);
  cursor: pointer;
  transition: color 0.15s;
}

.panel-tab:hover {
  color: var(--on-surface-variant);
}

.panel-tab.active {
  color: var(--primary);
  border-bottom-color: var(--primary);
}
```

**Step 2: Commit**

```bash
git add assets/css/app.css
git commit -m "style: add panel tab CSS"
```

---

### Task 4: Conditionally render activity feed vs session overview

**Files:**
- Modify: `lib/sam_web/live/dashboard_live.ex` (render function)

**Step 1: Wrap activity feed body in conditional**

Find the panel body div that contains the activity feed (starting with `<div class="sam-panel-body">` around line 628). Wrap the existing content in an `:if` and add the sessions view:

```heex
        <div class="sam-panel-body">
          <%= if @panel_view == :activity do %>
            <%= unless @summarizer_mode do %>
              <div class="ollama-nudge">
                Install
                <a href="https://ollama.com" target="_blank" style="color: var(--phosphor-green); text-decoration: underline;">
                  Ollama
                </a>
                for AI-powered summaries
              </div>
            <% end %>
            <%= if @selected_session do %>
              <% state = selected_state(@sessions, @selected_session) %>
              <%= if state do %>
                <div
                  :for={item <- Enum.take(Map.get(state, :activity, []), 50)}
                  class="activity-item"
                >
                  <span class="time">{format_time(item.timestamp)}</span>
                  <%= if Map.get(item, :tool_count, 0) > 0 do %>
                    <span class="tool-count">{item.tool_count}</span>
                  <% end %>
                  <span class={"msg #{activity_msg_class(item)}"} title={item.text}>{sanitize_text(item.text)}</span>
                </div>
              <% end %>
            <% end %>
          <% else %>
            <div
              :for={{id, state} <- Enum.sort_by(@sessions, fn {id, _} -> id end)}
              :if={!state[:ghost]}
              class={"session-card #{if id == @selected_session, do: "selected"}"}
              phx-click="select_session"
              phx-value-id={id}
            >
              <div class="session-card-top">
                <span class={"status-dot #{status_class(state.status)}"}></span>
                <span class="session-card-name">{state.name || id}</span>
                <span class="session-card-time">{format_uptime(state)}</span>
              </div>
              <div class="session-card-summary" title={raw_summary_text(state)}>
                {agent_activity_text(state)}
              </div>
            </div>
          <% end %>
        </div>
```

**Step 2: Add `raw_summary_text/1` helper**

Add a new private function near `agent_activity_text/1` (around line 364):

```elixir
  defp raw_summary_text(%{activity: [latest | _]}), do: latest.text
  defp raw_summary_text(%{summary: summary}) when is_binary(summary) and summary != "", do: summary
  defp raw_summary_text(_), do: "Awaiting directives"
```

Note: This helper returns the unsanitized text for the `title` tooltip, so users see the full text on hover. The sanitized version is displayed in the card via `agent_activity_text/1`.

**Step 3: Also add `title` attribute to activity feed items**

In the activity feed `:for` loop, the `<span class={"msg ..."}>` already got `title={item.text}` added in Step 1 above. This shows the full activity text on hover when truncated.

**Step 4: Run tests and verify compilation**

Run: `mix compile --warnings-as-errors && mix test`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/sam_web/live/dashboard_live.ex
git commit -m "feat: render session overview cards in SESSIONS tab"
```

---

### Task 5: Add CSS for session cards

**Files:**
- Modify: `assets/css/app.css`

**Step 1: Add session card styles**

Add after the panel tab CSS (added in Task 3):

```css
/* Session overview cards */
.session-card {
  padding: 8px 12px;
  border-bottom: 1px solid rgba(67, 71, 77, 0.12);
  cursor: pointer;
  transition: background 0.15s;
}

.session-card:hover {
  background: var(--surface-container);
}

.session-card.selected {
  background: var(--surface-container);
  border-left: 3px solid var(--primary);
  padding-left: 9px;
}

.session-card-top {
  display: flex;
  align-items: center;
  gap: 6px;
}

.session-card-name {
  font-family: var(--font-headline);
  font-size: 0.875rem;
  font-weight: 700;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  color: var(--on-surface);
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.session-card-time {
  font-family: var(--font-mono);
  font-size: 0.75rem;
  color: var(--outline);
  flex-shrink: 0;
}

.session-card-summary {
  font-family: var(--font-mono);
  font-size: 0.75rem;
  color: var(--outline);
  padding-left: 11px;
  margin-top: 2px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
```

**Step 2: Commit**

```bash
git add assets/css/app.css
git commit -m "style: add session card CSS for overview panel"
```

---

### Task 6: Verify end-to-end

**Step 1: Run full precommit**

Run: `mix precommit`
Expected: PASS

**Step 2: Manual verification**

1. Start server: `mix phx.server`
2. Open http://localhost:4040
3. Create 2+ sessions
4. Click "SESSIONS" tab — should show all sessions with name, time, summary
5. Click a session card — should switch to that session's terminal
6. Click "ACTIVITY" tab — should show the activity feed for selected session
7. Hover over truncated summary text — should show full text in tooltip
8. Hover over truncated activity feed items — should show full text in tooltip

**Step 3: Screenshot**

Use `mcp__screenshot-website-fast__take_screenshot` to capture the session overview view.

**Step 4: Final commit if any tweaks needed**
