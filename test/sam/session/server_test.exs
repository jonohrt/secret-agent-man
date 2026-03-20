defmodule Sam.Session.ServerTest do
  use ExUnit.Case, async: false

  describe "sanitize_utf8 via broadcast" do
    test "summary with invalid UTF-8 produces JSON-encodable broadcast" do
      session_id = "test-utf8-#{System.unique_integer([:positive])}"

      # Subscribe to UI updates before starting the server
      Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")

      # Start the server directly (no PTY/Parser needed for this test)
      {:ok, pid} =
        GenServer.start_link(Sam.Session.Server, %{session_id: session_id, name: "UTF8 Test"})

      # Drain the initial :running broadcast
      assert_receive {:session_update, ^session_id, _}, 1000

      # Simulate a summary containing invalid UTF-8 bytes
      # 0xAF is a continuation byte without a leading byte — the exact crash trigger
      bad_summary = "Working on " <> <<0xAF, 0xFF, 0xFE>> <> " task"

      Phoenix.PubSub.broadcast(
        Sam.PubSub,
        "session:#{session_id}",
        {:summary, session_id, %{summary: bad_summary, timestamp: DateTime.utc_now()}}
      )

      # Should receive the UI update with sanitized text
      assert_receive {:session_update, ^session_id, state}, 1000

      # THE CRITICAL ASSERTION: Jason.encode! must not crash
      assert {:ok, _json} = Jason.encode(Map.from_struct(state))

      # Activity should contain the sanitized summary
      assert [%{text: text} | _] = state.activity
      assert String.valid?(text)

      # ALSO verify get_state returns JSON-safe data (the load_sessions path)
      get_state = GenServer.call(pid, :get_state)
      assert {:ok, _json} = Jason.encode(Map.from_struct(get_state))
      assert [%{text: get_text} | _] = get_state.activity
      assert String.valid?(get_text)

      GenServer.stop(pid)
    end

    test "get_state returns sanitized data even with corrupted internal state", ctx do
      session_id = "test-getstate-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")

      {:ok, pid} =
        GenServer.start_link(Sam.Session.Server, %{session_id: session_id, name: "GetState Test"})

      assert_receive {:session_update, ^session_id, _}, 1000

      # Inject bad UTF-8 directly into server state to simulate stale data
      :sys.replace_state(pid, fn state ->
        bad_entry = %{type: :summary, text: <<0xAF>> <> " test", timestamp: DateTime.utc_now()}
        %{state | activity: [bad_entry]}
      end)

      # get_state must return JSON-safe data
      state = GenServer.call(pid, :get_state)
      assert {:ok, _json} = Jason.encode(Map.from_struct(state))
      assert [%{text: text}] = state.activity
      assert String.valid?(text)

      GenServer.stop(pid)
    end

    test "sanitize_utf8 replaces ALL invalid bytes, not just the first" do
      session_id = "test-allbytes-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")

      {:ok, pid} =
        GenServer.start_link(Sam.Session.Server, %{session_id: session_id, name: "AllBytes Test"})

      assert_receive {:session_update, ^session_id, _}, 1000

      # Multiple invalid bytes scattered throughout
      bad_text = "hello" <> <<0xFF>> <> "world" <> <<0xFE>> <> "end"

      Phoenix.PubSub.broadcast(
        Sam.PubSub,
        "session:#{session_id}",
        {:summary, session_id, %{summary: bad_text, timestamp: DateTime.utc_now()}}
      )

      assert_receive {:session_update, ^session_id, state}, 1000
      assert [%{text: text} | _] = state.activity
      assert String.valid?(text)
      # Should preserve the valid parts
      assert text =~ "hello"
      assert text =~ "world"
      assert text =~ "end"

      GenServer.stop(pid)
    end

    test "sanitize preserves valid multibyte UTF-8" do
      session_id = "test-multibyte-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")

      {:ok, pid} =
        GenServer.start_link(Sam.Session.Server, %{session_id: session_id, name: "Multibyte"})

      assert_receive {:session_update, ^session_id, _}, 1000

      # Valid UTF-8 with emoji and special chars — should pass through unchanged
      valid_text = "Working on task ❯ with émojis 🎉"

      Phoenix.PubSub.broadcast(
        Sam.PubSub,
        "session:#{session_id}",
        {:summary, session_id, %{summary: valid_text, timestamp: DateTime.utc_now()}}
      )

      assert_receive {:session_update, ^session_id, state}, 1000
      assert {:ok, _json} = Jason.encode(Map.from_struct(state))
      assert [%{text: ^valid_text} | _] = state.activity

      GenServer.stop(pid)
    end

    test "sanitize handles pure binary garbage" do
      session_id = "test-garbage-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")

      {:ok, pid} =
        GenServer.start_link(Sam.Session.Server, %{session_id: session_id, name: "Garbage Test"})

      assert_receive {:session_update, ^session_id, _}, 1000

      # Pure invalid bytes — no valid UTF-8 at all
      garbage = <<0x80, 0x81, 0xFE, 0xFF, 0xAF, 0xC0, 0xC1>>

      Phoenix.PubSub.broadcast(
        Sam.PubSub,
        "session:#{session_id}",
        {:summary, session_id, %{summary: garbage, timestamp: DateTime.utc_now()}}
      )

      assert_receive {:session_update, ^session_id, state}, 1000
      assert {:ok, _json} = Jason.encode(Map.from_struct(state))

      GenServer.stop(pid)
    end
  end

  describe "hook-event status detection" do
    setup do
      session_id = "test-status-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")

      {:ok, pid} =
        GenServer.start_link(Sam.Session.Server, %{
          session_id: session_id,
          name: "Status Test",
          idle_timeout_ms: 100
        })

      # Drain initial :running broadcast
      assert_receive {:session_update, ^session_id, %{status: :running}}, 1000

      %{session_id: session_id, pid: pid}
    end

    test "tool_call hook event transitions to :working", %{session_id: id, pid: pid} do
      send(
        pid,
        {:parser_event, id, %{type: :tool_call, tool: "Read", timestamp: DateTime.utc_now()}}
      )

      assert_receive {:session_update, ^id, %{status: :working}}, 1000
    end

    test "idle timeout after tool_result transitions to :idle", %{session_id: id, pid: pid} do
      # Start working
      send(
        pid,
        {:parser_event, id, %{type: :tool_call, tool: "Read", timestamp: DateTime.utc_now()}}
      )

      assert_receive {:session_update, ^id, %{status: :working}}, 1000

      # Tool finishes
      send(
        pid,
        {:parser_event, id, %{type: :tool_result, tool: "Read", timestamp: DateTime.utc_now()}}
      )

      # After idle timeout (100ms in test), should go idle
      assert_receive {:session_update, ^id, %{status: :idle}}, 1000
    end

    test "pty_output does NOT change status (JSONL watcher handles this)", %{
      session_id: id,
      pid: pid
    } do
      state = :sys.get_state(pid)
      assert state.status == :running

      send(pid, {:pty_output, id, String.duplicate("x", 500)})
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert state.status == :running
    end

    test "input_needed from PTY still transitions status", %{session_id: id, pid: pid} do
      send(pid, {:parser_event, id, %{type: :input_needed}})

      assert_receive {:session_update, ^id, %{status: :needs_input}}, 1000
    end

    test "new tool_call resets idle timer", %{session_id: id, pid: pid} do
      # Start working
      send(
        pid,
        {:parser_event, id, %{type: :tool_call, tool: "Read", timestamp: DateTime.utc_now()}}
      )

      assert_receive {:session_update, ^id, %{status: :working}}, 1000

      # Wait 50ms (half the idle timeout), then another tool_call
      Process.sleep(50)

      send(
        pid,
        {:parser_event, id, %{type: :tool_call, tool: "Edit", timestamp: DateTime.utc_now()}}
      )

      # Should NOT go idle after another 60ms (110ms total from first tool_call)
      refute_receive {:session_update, ^id, %{status: :idle}}, 60

      # But SHOULD go idle 100ms after the second tool_call
      assert_receive {:session_update, ^id, %{status: :idle}}, 200
    end
  end

  describe "session lifecycle" do
    test "creates a session via GroupSupervisor" do
      session_id = "test-server-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")
      Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

      {:ok, _sup_pid} =
        Sam.Session.GroupSupervisor.start_session(%{
          session_id: session_id,
          command: ["/bin/bash", "-l"],
          agent_type: :generic,
          name: "Test Session"
        })

      # Session should be registered and retrievable
      state = Sam.Session.Server.get_state(session_id)
      assert state.status == :running
      assert state.name == "Test Session"

      # Should be in list_sessions
      assert session_id in Sam.Session.Server.list_sessions()

      # Send input through the session
      Sam.Session.Server.send_input(session_id, "echo lifecycle_test\n")

      # Should get PTY output via PubSub
      assert_receive {:pty_output, ^session_id, _data}, 5000

      # Clean up
      Sam.Session.Server.stop(session_id)
    end
  end
end
