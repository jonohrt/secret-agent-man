defmodule SamWeb.Components.DirectoryPicker do
  use Phoenix.LiveComponent

  @impl true
  def mount(socket) do
    {:ok, assign(socket, browsing: false, current_dir: nil, error: nil)}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:current_dir, fn -> assigns[:base_path] || "" end)
      |> assign_new(:browsing, fn -> false end)

    {:ok, socket}
  end

  @impl true
  def handle_event("browse_toggle", _params, socket) do
    browsing = !socket.assigns.browsing
    current_dir = if browsing, do: socket.assigns.base_path, else: socket.assigns.current_dir
    {:noreply, assign(socket, browsing: browsing, current_dir: current_dir, error: nil)}
  end

  def handle_event("navigate", %{"path" => path}, socket) do
    expanded = expand_path(path)

    if File.dir?(expanded) do
      {:noreply, assign(socket, current_dir: expanded, error: nil)}
    else
      {:noreply, assign(socket, error: "Not a directory")}
    end
  end

  def handle_event("select_dir", %{"path" => path}, socket) do
    send(self(), {:directory_selected, expand_path(path)})
    {:noreply, assign(socket, browsing: false)}
  end

  def handle_event("select_mru", %{"path" => path}, socket) do
    send(self(), {:directory_selected, path})
    {:noreply, socket}
  end

  def handle_event("navigate_up", _params, socket) do
    parent = Path.dirname(socket.assigns.current_dir)
    {:noreply, assign(socket, current_dir: parent, error: nil)}
  end

  @impl true
  def render(assigns) do
    dirs = if assigns[:browsing], do: list_dirs(assigns.current_dir), else: []
    assigns = assign(assigns, :dirs, dirs)

    ~H"""
    <div class="directory-picker">
      <%!-- MRU chips --%>
      <div :if={@mru_paths != []} class="picker-mru">
        <span
          :for={path <- @mru_paths}
          class="picker-chip"
          phx-click="select_mru"
          phx-value-path={path}
          phx-target={@myself}
        >
          {Path.relative_to(path, @base_path)}
        </span>
        <span class="picker-mru-label">recent</span>
      </div>

      <%!-- Path input + browse button --%>
      <div class="picker-input-row">
        <input
          type="text"
          name="workdir"
          value={@selected_path}
          class="modal-input"
          style="font-family: var(--font-mono); font-size: 10px; flex: 1;"
        />
        <button
          type="button"
          class="picker-browse-btn"
          phx-click="browse_toggle"
          phx-target={@myself}
        >
          {if @browsing, do: "CLOSE", else: "BROWSE"}
        </button>
      </div>

      <%!-- Directory tree --%>
      <div :if={@browsing} class="picker-tree">
        <div class="picker-breadcrumb">{@current_dir}</div>
        <div :if={@error} class="picker-error">{@error}</div>

        <div
          :if={@current_dir != "/"}
          class="picker-dir"
          phx-click="navigate_up"
          phx-target={@myself}
        >
          📂 ..
        </div>

        <div
          :for={dir <- @dirs}
          class="picker-dir"
          phx-click="navigate"
          phx-value-path={Path.join(@current_dir, dir)}
          phx-target={@myself}
        >
          📂 {dir}/
          <button
            type="button"
            class="picker-select-btn"
            phx-click="select_dir"
            phx-value-path={Path.join(@current_dir, dir)}
            phx-target={@myself}
          >
            SELECT
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp list_dirs(nil), do: []

  defp list_dirs(path) do
    expanded = expand_path(path)

    case File.ls(expanded) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.filter(&File.dir?(Path.join(expanded, &1)))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp expand_path(path) do
    if String.starts_with?(path, "~") do
      String.replace_prefix(path, "~", System.user_home!())
    else
      path
    end
  end
end
