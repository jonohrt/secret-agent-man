# lib/sam/session/journal_finder.ex
defmodule Sam.Session.JournalFinder do
  @moduledoc """
  Watches a directory for new .jsonl files created by Claude Code.
  When found, sends {:journal_found, path} to the TranscriptWatcher.
  Self-terminates the watcher after finding the file.
  """
  use GenServer
  require Logger

  @default_timeout_ms 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    session_id = Map.fetch!(opts, :session_id)
    watch_dir = Map.fetch!(opts, :watch_dir)
    notify_pid = Map.get(opts, :notify_pid)
    timeout_ms = Map.get(opts, :timeout_ms, @default_timeout_ms)

    File.mkdir_p!(watch_dir)

    {:ok, watcher_pid} = FileSystem.start_link(dirs: [watch_dir])
    FileSystem.subscribe(watcher_pid)

    timer_ref = Process.send_after(self(), :timeout, timeout_ms)

    {:ok,
     %{
       session_id: session_id,
       watch_dir: watch_dir,
       watcher_pid: watcher_pid,
       notify_pid: notify_pid,
       timer_ref: timer_ref,
       found: false
     }}
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, events}}, %{found: false} = state) do
    if String.ends_with?(path, ".jsonl") and :created in events do
      Logger.info("[JournalFinder] Found JSONL: #{Path.basename(path)}")

      # Notify TranscriptWatcher (or test pid)
      notify_target(state, path)

      # Stop the filesystem watcher (no longer needed)
      Process.unlink(state.watcher_pid)

      try do
        GenServer.stop(state.watcher_pid)
      catch
        :exit, _ -> :ok
      end

      Process.cancel_timer(state.timer_ref)

      {:noreply, %{state | found: true}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _watcher_pid, {_path, _events}}, state) do
    # Already found — ignore
    {:noreply, state}
  end

  def handle_info(:timeout, %{found: false} = state) do
    Logger.warning(
      "[JournalFinder] Timeout waiting for JSONL file for session #{state.session_id}"
    )

    Process.unlink(state.watcher_pid)

    try do
      GenServer.stop(state.watcher_pid)
    catch
      :exit, _ -> :ok
    end

    {:noreply, %{state | found: false}}
  end

  def handle_info(:timeout, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{found: false} = state) do
    # Cleanup watcher if still running
    Process.unlink(state.watcher_pid)

    try do
      GenServer.stop(state.watcher_pid)
    catch
      :exit, _ -> :ok
    end
  end

  def terminate(_reason, _state), do: :ok

  defp notify_target(%{notify_pid: pid}, path) when is_pid(pid) do
    send(pid, {:journal_found, path})
  end

  defp notify_target(%{session_id: session_id}, path) do
    case Registry.lookup(Sam.ProcessRegistry, {:transcript_watcher, session_id}) do
      [{pid, _}] ->
        send(pid, {:journal_found, path})

      [] ->
        Logger.warning("[JournalFinder] TranscriptWatcher not found for #{session_id}")
    end
  end
end
