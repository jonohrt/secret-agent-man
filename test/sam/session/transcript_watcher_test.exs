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

  describe "deterministic JSONL path from claude_session_id" do
    @tag :tmp_dir
    test "constructs deterministic JSONL path from claude_session_id", %{tmp_dir: tmp_dir} do
      session_id = "test-det-#{System.unique_integer([:positive])}"
      claude_session_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

      project_dir = Path.join(tmp_dir, "project")
      File.mkdir_p!(project_dir)
      jsonl_path = Path.join(project_dir, "#{claude_session_id}.jsonl")
      File.write!(jsonl_path, "")

      Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

      {:ok, pid} =
        GenServer.start_link(Sam.Session.TranscriptWatcher, %{
          session_id: session_id,
          workdir: nil,
          claude_session_id: claude_session_id,
          _test_project_dir: project_dir
        })

      Process.sleep(1500)

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
    test "waits for JSONL file to appear when claude_session_id given but file not yet created",
         %{tmp_dir: tmp_dir} do
      session_id = "test-wait-#{System.unique_integer([:positive])}"
      claude_session_id = "11111111-2222-3333-4444-555555555555"

      project_dir = Path.join(tmp_dir, "project")
      File.mkdir_p!(project_dir)
      jsonl_path = Path.join(project_dir, "#{claude_session_id}.jsonl")
      # NOTE: File does NOT exist yet

      Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

      {:ok, pid} =
        GenServer.start_link(Sam.Session.TranscriptWatcher, %{
          session_id: session_id,
          workdir: nil,
          claude_session_id: claude_session_id,
          _test_project_dir: project_dir
        })

      # Should be in waiting_for_file state
      state = :sys.get_state(pid)
      assert state.waiting_for_file == true

      # Now create the file and write data
      File.write!(jsonl_path, "")
      Process.sleep(1500)

      record =
        Jason.encode!(%{
          "message" => %{
            "role" => "assistant",
            "content" => [
              %{"type" => "tool_use", "id" => "t1", "name" => "Bash", "input" => %{}}
            ]
          }
        })

      File.write!(jsonl_path, record <> "\n", [:append])
      assert_receive {:parser_event, ^session_id, %{type: :tool_call, tool: "Bash"}}, 3000

      GenServer.stop(pid)
    end
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
  test "emits turn_end for turn_duration system record", %{tmp_dir: tmp_dir} do
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

    assert_receive {:parser_event, ^session_id, %{type: :turn_end}}, 3000

    GenServer.stop(pid)
  end

  @tag :tmp_dir
  test "emits user_prompt for user record with string content", %{tmp_dir: tmp_dir} do
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
        "type" => "user",
        "message" => %{"role" => "user", "content" => "fix the bug"}
      })

    File.write!(jsonl_path, record <> "\n", [:append])

    assert_receive {:parser_event, ^session_id, %{type: :user_prompt}}, 3000

    GenServer.stop(pid)
  end

  @tag :tmp_dir
  test "emits assistant_response for text-only assistant message", %{tmp_dir: tmp_dir} do
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
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Hello!"}]
        }
      })

    File.write!(jsonl_path, record <> "\n", [:append])

    assert_receive {:parser_event, ^session_id, %{type: :assistant_response}}, 3000

    GenServer.stop(pid)
  end
end
