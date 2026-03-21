# test/sam/session/journal_finder_test.exs
defmodule Sam.Session.JournalFinderTest do
  use ExUnit.Case, async: false

  @tag :tmp_dir
  test "detects new .jsonl file in watched directory", %{tmp_dir: tmp_dir} do
    session_id = "test-jf-#{System.unique_integer([:positive])}"
    watch_dir = Path.join(tmp_dir, "watch")
    File.mkdir_p!(watch_dir)

    test_pid = self()

    {:ok, pid} =
      GenServer.start_link(Sam.Session.JournalFinder, %{
        session_id: session_id,
        watch_dir: watch_dir,
        notify_pid: test_pid
      })

    # Give FileSystem watcher time to start
    Process.sleep(500)

    # Create a .jsonl file
    jsonl_path = Path.join(watch_dir, "test-session.jsonl")
    File.write!(jsonl_path, "")

    assert_receive {:journal_found, ^jsonl_path}, 5000

    GenServer.stop(pid)
  end

  @tag :tmp_dir
  test "ignores non-.jsonl files", %{tmp_dir: tmp_dir} do
    session_id = "test-jf-ignore-#{System.unique_integer([:positive])}"
    watch_dir = Path.join(tmp_dir, "watch")
    File.mkdir_p!(watch_dir)

    test_pid = self()

    {:ok, pid} =
      GenServer.start_link(Sam.Session.JournalFinder, %{
        session_id: session_id,
        watch_dir: watch_dir,
        notify_pid: test_pid
      })

    Process.sleep(500)

    # Create a non-jsonl file
    File.write!(Path.join(watch_dir, "not-a-journal.txt"), "")

    refute_receive {:journal_found, _}, 2000

    GenServer.stop(pid)
  end

  @tag :tmp_dir
  test "timeout triggers warning and stays idle", %{tmp_dir: tmp_dir} do
    session_id = "test-jf-timeout-#{System.unique_integer([:positive])}"
    watch_dir = Path.join(tmp_dir, "watch")
    File.mkdir_p!(watch_dir)

    test_pid = self()

    {:ok, pid} =
      GenServer.start_link(Sam.Session.JournalFinder, %{
        session_id: session_id,
        watch_dir: watch_dir,
        notify_pid: test_pid,
        timeout_ms: 500
      })

    # Wait for timeout
    Process.sleep(1000)

    # Should not have sent journal_found
    refute_receive {:journal_found, _}, 100

    # Process should still be alive
    assert Process.alive?(pid)

    GenServer.stop(pid)
  end
end
