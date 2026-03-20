defmodule Sam.Session.TranscriptWatcherTest do
  use ExUnit.Case, async: true

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

    # Give the watcher time to find the file and set offset
    Process.sleep(100)

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

    Process.sleep(100)

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

    Process.sleep(100)

    record = Jason.encode!(%{"type" => "system", "subtype" => "turn_duration"})
    File.write!(jsonl_path, record <> "\n", [:append])

    assert_receive {:parser_event, ^session_id, %{type: :tool_result, tool: "turn_end"}}, 3000

    GenServer.stop(pid)
  end
end
