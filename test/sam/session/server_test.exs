defmodule Sam.Session.ServerTest do
  use ExUnit.Case, async: false

  describe "UTF-8 safety" do
    test "get_state returns sanitized data even with corrupted internal state" do
      session_id = "test-getstate-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")

      {:ok, pid} =
        GenServer.start_link(Sam.Session.Server, %{session_id: session_id, name: "GetState Test"})

      assert_receive {:session_update, ^session_id, _}, 1000

      # Inject bad UTF-8 directly into server state to simulate stale data
      :sys.replace_state(pid, fn state ->
        bad_entry = %{type: :tool, text: <<0xAF>> <> " test", timestamp: DateTime.utc_now()}
        %{state | activity: [bad_entry]}
      end)

      # get_state must return JSON-safe data
      state = GenServer.call(pid, :get_state)
      assert {:ok, _json} = Jason.encode(Map.from_struct(state))
      assert [%{text: text}] = state.activity
      assert String.valid?(text)

      GenServer.stop(pid)
    end

    test "tool activity with invalid UTF-8 is sanitized" do
      session_id = "test-utf8-tool-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")

      {:ok, pid} =
        GenServer.start_link(Sam.Session.Server, %{session_id: session_id, name: "UTF8 Test"})

      assert_receive {:session_update, ^session_id, _}, 1000

      # Send a tool event (which adds to activity)
      send(
        pid,
        {:parser_event, session_id,
         %{type: :pre_tool_call, tool: "Read", timestamp: DateTime.utc_now()}}
      )

      assert_receive {:session_update, ^session_id, state}, 1000
      assert {:ok, _json} = Jason.encode(Map.from_struct(state))
      assert [%{text: "Read"} | _] = state.activity

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

      # Drain initial :idle broadcast
      assert_receive {:session_update, ^session_id, %{status: :idle}}, 1000

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
      assert state.status == :idle

      send(pid, {:pty_output, id, String.duplicate("x", 500)})
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert state.status == :idle
    end

    test "input_needed from PTY still transitions status", %{session_id: id, pid: pid} do
      send(pid, {:parser_event, id, %{type: :input_needed}})

      assert_receive {:session_update, ^id, %{status: :needs_input}}, 1000
    end

    test "stays working until post_tool_call + idle timeout", %{session_id: id, pid: pid} do
      # Start working
      send(
        pid,
        {:parser_event, id, %{type: :pre_tool_call, tool: "Bash", timestamp: DateTime.utc_now()}}
      )

      assert_receive {:session_update, ^id, %{status: :working}}, 1000

      # Should NOT go idle even after 150ms — no post_tool_call yet
      refute_receive {:session_update, ^id, %{status: :idle}}, 150

      # Tool finishes
      send(
        pid,
        {:parser_event, id, %{type: :post_tool_call, tool: "Bash", timestamp: DateTime.utc_now()}}
      )

      # NOW should go idle after the 100ms timeout
      assert_receive {:session_update, ^id, %{status: :idle}}, 300
    end
  end

  describe "initial status" do
    test "new session starts as :idle, not :running" do
      session_id = "test-init-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")

      {:ok, pid} =
        GenServer.start_link(Sam.Session.Server, %{session_id: session_id, name: "Init Test"})

      # The first broadcast should show :idle — a fresh session waiting for input is idle
      assert_receive {:session_update, ^session_id, %{status: :idle}}, 1000

      # Direct state check too
      state = :sys.get_state(pid)
      assert state.status == :idle

      GenServer.stop(pid)
    end
  end

  describe "agent title fallback" do
    test "agent entry gets fallback description when hook sends empty string" do
      session_id = "test-agent-title-#{System.unique_integer([:positive])}"
      opts = %{session_id: session_id}
      pid = start_supervised!({Sam.Session.Server, opts})

      event = %{
        type: :tool_call,
        tool: "Agent",
        description: "",
        file: nil,
        session_id: session_id,
        timestamp: DateTime.utc_now()
      }

      Phoenix.PubSub.broadcast(
        Sam.PubSub,
        "session:#{session_id}",
        {:parser_event, session_id, event}
      )

      :sys.get_state(pid)

      state = Sam.Session.Server.get_state(session_id)
      agent = List.first(state.agents)
      assert agent.description == "subagent"
      assert agent.description != ""
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
      assert state.status == :idle
      assert state.name == "Test Session"

      # Should be in list_sessions
      assert session_id in Sam.Session.Server.list_sessions()

      # Send input through the session
      Sam.Session.Server.send_input(session_id, "echo lifecycle_test\n")

      # Should get PTY output via PubSub
      assert_receive {:pty_output, ^session_id, _data}, 5000

      # Clean up
      Sam.Session.GroupSupervisor.terminate_session(session_id)
    end

    test "terminate_session fully removes session (no ghost restarts)" do
      session_id = "test-terminate-#{System.unique_integer([:positive])}"

      {:ok, _sup_pid} =
        Sam.Session.GroupSupervisor.start_session(%{
          session_id: session_id,
          command: ["/bin/bash", "-l"],
          agent_type: :generic,
          name: "Ghost Test"
        })

      assert session_id in Sam.Session.Server.list_sessions()

      # Terminate the session
      :ok = Sam.Session.GroupSupervisor.terminate_session(session_id)
      Process.sleep(200)

      # Session must be fully gone — not restarted by supervisor
      refute session_id in Sam.Session.Server.list_sessions()
    end
  end
end
