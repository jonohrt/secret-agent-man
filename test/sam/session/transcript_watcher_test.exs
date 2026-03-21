defmodule Sam.Session.TranscriptWatcherTest do
  use ExUnit.Case, async: true

  describe "JSONL file discovery" do
    @tag :tmp_dir
    test "only reads content appended after watcher locks on", %{tmp_dir: tmp_dir} do
      session_id = "test-skip-old-#{System.unique_integer([:positive])}"

      project_dir = Path.join(tmp_dir, "project")
      File.mkdir_p!(project_dir)

      # File with pre-existing content
      jsonl = Path.join(project_dir, "session.jsonl")

      old_record =
        Jason.encode!(%{
          "message" => %{
            "role" => "assistant",
            "content" => [
              %{"type" => "tool_use", "id" => "old", "name" => "Edit", "input" => %{}}
            ]
          }
        })

      File.write!(jsonl, old_record <> "\n")

      Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

      {:ok, pid} =
        GenServer.start_link(Sam.Session.TranscriptWatcher, %{
          session_id: session_id,
          workdir: nil,
          _test_jsonl_path: jsonl
        })

      # Should NOT emit events from pre-existing content
      refute_receive {:parser_event, ^session_id, _}, 2000

      # But NEW content appended after watcher starts should emit
      new_record =
        Jason.encode!(%{
          "message" => %{
            "role" => "assistant",
            "content" => [
              %{"type" => "tool_use", "id" => "new", "name" => "Bash", "input" => %{}}
            ]
          }
        })

      File.write!(jsonl, new_record <> "\n", [:append])

      assert_receive {:parser_event, ^session_id, %{type: :tool_call, tool: "Bash"}}, 3000

      GenServer.stop(pid)
    end
  end

  @tag :tmp_dir
  test "transitions from waiting to watching on journal_found", %{tmp_dir: tmp_dir} do
    session_id = "test-tw-jf-#{System.unique_integer([:positive])}"
    jsonl_path = Path.join(tmp_dir, "session.jsonl")
    File.write!(jsonl_path, "")

    Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

    # Start watcher WITHOUT a test path (simulates waiting state)
    {:ok, pid} =
      GenServer.start_link(Sam.Session.TranscriptWatcher, %{
        session_id: session_id,
        workdir: nil,
        _test_project_dir: Path.join(tmp_dir, "nonexistent")
      })

    # Verify it's in waiting state (no path found)
    state = :sys.get_state(pid)
    assert state.path == nil

    # Send journal_found
    send(pid, {:journal_found, jsonl_path})

    # Give it time to process
    Process.sleep(200)

    # Now append data and verify events flow
    record =
      Jason.encode!(%{
        "message" => %{
          "role" => "assistant",
          "content" => [
            %{"type" => "tool_use", "id" => "t1", "name" => "Read", "input" => %{}}
          ]
        }
      })

    File.write!(jsonl_path, record <> "\n", [:append])
    assert_receive {:parser_event, ^session_id, %{type: :tool_call, tool: "Read"}}, 3000

    GenServer.stop(pid)
  end

  @tag :tmp_dir
  test "emits tool_call event from assistant tool_use record", %{tmp_dir: tmp_dir} do
    session_id = "test-tw-#{System.unique_integer([:positive])}"
    jsonl_path = Path.join(tmp_dir, "test-session.jsonl")
    File.write!(jsonl_path, "")

    Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

    {:ok, pid} =
      GenServer.start_link(Sam.Session.TranscriptWatcher, %{
        session_id: session_id,
        workdir: nil,
        _test_jsonl_path: jsonl_path
      })

    # Wait for the watcher to process init and set offset
    _ = :sys.get_state(pid)

    # Append a tool_use record
    record =
      Jason.encode!(%{
        "message" => %{
          "role" => "assistant",
          "content" => [%{"type" => "tool_use", "id" => "t1", "name" => "Read", "input" => %{}}]
        }
      })

    File.write!(jsonl_path, record <> "\n", [:append])

    assert_receive {:parser_event, ^session_id, %{type: :tool_call, tool: "Read"}}, 3000

    GenServer.stop(pid)
  end

  @tag :tmp_dir
  test "emits tool_result event from user tool_result record", %{tmp_dir: tmp_dir} do
    session_id = "test-tw-#{System.unique_integer([:positive])}"
    jsonl_path = Path.join(tmp_dir, "test-session.jsonl")
    File.write!(jsonl_path, "")

    Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

    {:ok, pid} =
      GenServer.start_link(Sam.Session.TranscriptWatcher, %{
        session_id: session_id,
        workdir: nil,
        _test_jsonl_path: jsonl_path
      })

    _ = :sys.get_state(pid)

    record =
      Jason.encode!(%{
        "message" => %{
          "role" => "user",
          "content" => [%{"type" => "tool_result", "tool_use_id" => "t1", "content" => "ok"}]
        }
      })

    File.write!(jsonl_path, record <> "\n", [:append])

    assert_receive {:parser_event, ^session_id, %{type: :tool_result}}, 3000

    GenServer.stop(pid)
  end

  @tag :tmp_dir
  test "emits tool_result for turn_duration system record", %{tmp_dir: tmp_dir} do
    session_id = "test-tw-#{System.unique_integer([:positive])}"
    jsonl_path = Path.join(tmp_dir, "test-session.jsonl")
    File.write!(jsonl_path, "")

    Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

    {:ok, pid} =
      GenServer.start_link(Sam.Session.TranscriptWatcher, %{
        session_id: session_id,
        workdir: nil,
        _test_jsonl_path: jsonl_path
      })

    _ = :sys.get_state(pid)

    record = Jason.encode!(%{"type" => "system", "subtype" => "turn_duration"})
    File.write!(jsonl_path, record <> "\n", [:append])

    assert_receive {:parser_event, ^session_id, %{type: :tool_result, tool: "turn_end"}}, 3000

    GenServer.stop(pid)
  end
end
