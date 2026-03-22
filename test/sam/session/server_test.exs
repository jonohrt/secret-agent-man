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

    test "tool_call no longer adds to activity (only summaries do)" do
      session_id = "test-no-activity-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")

      {:ok, pid} =
        GenServer.start_link(Sam.Session.Server, %{session_id: session_id, name: "NoAct Test"})

      assert_receive {:session_update, ^session_id, _}, 1000

      # Send a tool event — should NOT add to activity
      send(
        pid,
        {:parser_event, session_id,
         %{type: :tool_call, tool: "Read", timestamp: DateTime.utc_now()}}
      )

      assert_receive {:session_update, ^session_id, state}, 1000
      assert state.activity == []

      GenServer.stop(pid)
    end
  end

  describe "JSONL event status detection" do
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

    test "stays working until tool_result + idle timeout", %{session_id: id, pid: pid} do
      # Start working
      send(
        pid,
        {:parser_event, id, %{type: :tool_call, tool: "Bash", timestamp: DateTime.utc_now()}}
      )

      assert_receive {:session_update, ^id, %{status: :working}}, 1000

      # Should NOT go idle even after 150ms — no tool_result yet
      refute_receive {:session_update, ^id, %{status: :idle}}, 150

      # Tool finishes
      send(
        pid,
        {:parser_event, id, %{type: :tool_result, tool: "Bash", timestamp: DateTime.utc_now()}}
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

  describe "started_at" do
    test "server sets started_at on init" do
      session_id = "test-uptime-#{System.unique_integer([:positive])}"
      before = DateTime.utc_now()
      opts = %{session_id: session_id}
      _pid = start_supervised!({Sam.Session.Server, opts})

      state = Sam.Session.Server.get_state(session_id)
      assert %DateTime{} = state.started_at
      assert DateTime.compare(state.started_at, before) in [:gt, :eq]
    end
  end

  describe "branch detection" do
    test "server populates branch from git on init" do
      session_id = "test-branch-#{System.unique_integer([:positive])}"
      workdir = File.cwd!()
      opts = %{session_id: session_id, workdir: workdir}
      _pid = start_supervised!({Sam.Session.Server, opts})

      state = Sam.Session.Server.get_state(session_id)
      assert is_binary(state.branch)
      assert state.branch != ""
      assert state.branch != nil
    end
  end

  describe "summary events" do
    test "summary event updates activity feed" do
      session_id = "test-summary-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")

      {:ok, pid} =
        GenServer.start_link(Sam.Session.Server, %{session_id: session_id, name: "Sum Test"})

      assert_receive {:session_update, ^session_id, %{status: :idle}}, 1000

      Phoenix.PubSub.broadcast(
        Sam.PubSub,
        "session:#{session_id}",
        {:summary, session_id,
         %{
           text: "Fixed auth bug in login.ex, tests passing",
           tool_count: 2,
           timestamp: DateTime.utc_now()
         }}
      )

      assert_receive {:session_update, ^session_id, state}, 1000

      assert [
               %{text: "Fixed auth bug in login.ex, tests passing", type: :summary, tool_count: 2}
               | _
             ] =
               state.activity

      GenServer.stop(pid)
    end

    test "summary event updates dedicated summary field" do
      session_id = "test-summary-field-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")

      {:ok, pid} =
        GenServer.start_link(Sam.Session.Server, %{session_id: session_id, name: "SumField Test"})

      assert_receive {:session_update, ^session_id, %{summary: "Awaiting directives..."}}, 1000

      Phoenix.PubSub.broadcast(
        Sam.PubSub,
        "session:#{session_id}",
        {:summary, session_id,
         %{
           text: "Refactoring auth module",
           source: :ollama,
           tool_count: 3,
           timestamp: DateTime.utc_now()
         }}
      )

      assert_receive {:session_update, ^session_id, state}, 1000
      assert state.summary == "Refactoring auth module"

      # Activity list should ALSO have it (for the chronological feed)
      assert [%{text: "Refactoring auth module"} | _] = state.activity

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

  describe "rename/2" do
    test "updates name in state" do
      session_id = "test-rename-#{System.unique_integer([:positive])}"
      _pid = start_supervised!({Sam.Session.Server, %{session_id: session_id, name: "Old Name"}})

      assert :ok = Sam.Session.Server.rename(session_id, "New Name")

      state = Sam.Session.Server.get_state(session_id)
      assert state.name == "New Name"
    end

    test "broadcasts UI update on rename" do
      session_id = "test-rename-bc-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")

      _pid = start_supervised!({Sam.Session.Server, %{session_id: session_id, name: "Before"}})
      assert_receive {:session_update, ^session_id, %{name: "Before"}}, 1000

      Sam.Session.Server.rename(session_id, "After")
      assert_receive {:session_update, ^session_id, %{name: "After"}}, 1000
    end

    test "trims whitespace from name" do
      session_id = "test-rename-trim-#{System.unique_integer([:positive])}"
      _pid = start_supervised!({Sam.Session.Server, %{session_id: session_id, name: "Old"}})

      Sam.Session.Server.rename(session_id, "  Trimmed  ")

      state = Sam.Session.Server.get_state(session_id)
      assert state.name == "Trimmed"
    end

    test "rejects empty name" do
      session_id = "test-rename-empty-#{System.unique_integer([:positive])}"
      _pid = start_supervised!({Sam.Session.Server, %{session_id: session_id, name: "Keep Me"}})

      assert {:error, :empty_name} = Sam.Session.Server.rename(session_id, "")
      assert {:error, :empty_name} = Sam.Session.Server.rename(session_id, "   ")

      state = Sam.Session.Server.get_state(session_id)
      assert state.name == "Keep Me"
    end
  end

  describe "JSONL-driven status" do
    setup do
      session_id = "test-jsonl-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")

      {:ok, pid} =
        GenServer.start_link(Sam.Session.Server, %{
          session_id: session_id,
          name: "JSONL Test",
          idle_timeout_ms: 100,
          needs_input_timeout_ms: 200
        })

      assert_receive {:session_update, ^session_id, %{status: :idle}}, 1000
      %{session_id: session_id, pid: pid}
    end

    test "turn_end event transitions immediately to :idle (no timer)", %{
      session_id: id,
      pid: pid
    } do
      # Start working
      send(
        pid,
        {:parser_event, id, %{type: :tool_call, tool: "Read", timestamp: DateTime.utc_now()}}
      )

      assert_receive {:session_update, ^id, %{status: :working}}, 1000

      # turn_end = immediate idle, no waiting for timer
      send(pid, {:parser_event, id, %{type: :turn_end, timestamp: DateTime.utc_now()}})
      assert_receive {:session_update, ^id, %{status: :idle}}, 500
    end

    test "needs_input_timeout fires after silence during tool execution", %{
      session_id: id,
      pid: pid
    } do
      # Start working with a non-exempt tool
      send(
        pid,
        {:parser_event, id,
         %{
           type: :tool_call,
           tool: "Bash",
           timestamp: DateTime.utc_now()
         }}
      )

      assert_receive {:session_update, ^id, %{status: :working}}, 1000

      # After needs_input_timeout_ms (200ms in test), should go to needs_input
      assert_receive {:session_update, ^id, %{status: :needs_input}}, 1000
    end

    test "user_prompt transitions to :working", %{session_id: id, pid: pid} do
      send(pid, {:parser_event, id, %{type: :user_prompt, timestamp: DateTime.utc_now()}})
      assert_receive {:session_update, ^id, %{status: :working}}, 1000
    end

    test "assistant_response transitions to :working", %{session_id: id, pid: pid} do
      send(pid, {:parser_event, id, %{type: :assistant_response, timestamp: DateTime.utc_now()}})
      assert_receive {:session_update, ^id, %{status: :working}}, 1000
    end

    test "needs_input timer does NOT fire for exempt tools (Agent)", %{
      session_id: id,
      pid: pid
    } do
      send(
        pid,
        {:parser_event, id,
         %{
           type: :tool_call,
           tool: "Agent",
           description: "test",
           timestamp: DateTime.utc_now()
         }}
      )

      assert_receive {:session_update, ^id, %{status: :working}}, 1000

      # Should NOT go to needs_input — Agent is exempt
      refute_receive {:session_update, ^id, %{status: :needs_input}}, 400
    end

    test "tool_result cancels needs_input timer", %{
      session_id: id,
      pid: pid
    } do
      send(
        pid,
        {:parser_event, id, %{type: :tool_call, tool: "Bash", timestamp: DateTime.utc_now()}}
      )

      assert_receive {:session_update, ^id, %{status: :working}}, 1000

      # Immediately send tool_result (before needs_input timeout)
      send(
        pid,
        {:parser_event, id, %{type: :tool_result, tool: "Bash", timestamp: DateTime.utc_now()}}
      )

      # Should NOT go to needs_input — timer was cancelled
      refute_receive {:session_update, ^id, %{status: :needs_input}}, 400
    end

    test "pty_output with prompt at line boundary transitions to idle when no JSONL turn active",
         %{
           session_id: id,
           pid: pid
         } do
      # Set working WITHOUT jsonl_turn_active (simulates non-Claude session)
      :sys.replace_state(pid, fn state ->
        %{state | status: :working, jsonl_turn_active: false}
      end)

      # PTY output with prompt at line boundary should go idle
      send(pid, {:pty_output, id, "some output\r\n\e[1m❯\e[0m "})
      assert_receive {:session_update, ^id, %{status: :idle}}, 500
    end

    test "pty_output with ❯ embedded in content does NOT change status", %{
      session_id: id,
      pid: pid
    } do
      send(pid, {:parser_event, id, %{type: :assistant_response, timestamp: DateTime.utc_now()}})
      assert_receive {:session_update, ^id, %{status: :working}}, 1000

      # ❯ embedded in tool output (not at line boundary) should NOT trigger idle
      send(pid, {:pty_output, id, "The arrow ❯ points right"})
      refute_receive {:session_update, ^id, %{status: :idle}}, 300
    end

    test "pty_output without prompt character does NOT change status", %{
      session_id: id,
      pid: pid
    } do
      send(pid, {:parser_event, id, %{type: :assistant_response, timestamp: DateTime.utc_now()}})
      assert_receive {:session_update, ^id, %{status: :working}}, 1000

      # Normal output without ❯ should NOT change status
      send(pid, {:pty_output, id, "Hello, the answer is 4.\r\n"})
      refute_receive {:session_update, ^id, %{status: :idle}}, 300
    end

    test "pty_output prompt detection only fires when working", %{
      session_id: id,
      pid: pid
    } do
      # Should be idle already
      state = :sys.get_state(pid)
      assert state.status == :idle

      # Prompt at line boundary while idle should NOT trigger a broadcast
      send(pid, {:pty_output, id, "\r\n❯ "})
      refute_receive {:session_update, ^id, _}, 300
    end

    test "JSONL events after turn_end start a new turn", %{
      session_id: id,
      pid: pid
    } do
      # Start working
      send(pid, {:parser_event, id, %{type: :assistant_response, timestamp: DateTime.utc_now()}})
      assert_receive {:session_update, ^id, %{status: :working}}, 1000

      # Turn ends → idle, clears jsonl_turn_active
      send(pid, {:parser_event, id, %{type: :turn_end, timestamp: DateTime.utc_now()}})
      assert_receive {:session_update, ^id, %{status: :idle}}, 500

      # New JSONL events should start a new turn normally
      send(pid, {:parser_event, id, %{type: :user_prompt, timestamp: DateTime.utc_now()}})
      assert_receive {:session_update, ^id, %{status: :working}}, 1000
    end
  end

  describe "PTY prompt vs JSONL race condition" do
    setup do
      session_id = "test-race-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")

      {:ok, pid} =
        GenServer.start_link(Sam.Session.Server, %{
          session_id: session_id,
          name: "Race Test",
          idle_timeout_ms: 5_000,
          needs_input_timeout_ms: 5_000
        })

      assert_receive {:session_update, ^session_id, %{status: :idle}}, 1000
      %{session_id: session_id, pid: pid}
    end

    test "PTY prompt ignored during active JSONL turn", %{
      session_id: id,
      pid: pid
    } do
      # 1. JSONL: tool_call → working (sets jsonl_turn_active)
      send(
        pid,
        {:parser_event, id, %{type: :tool_call, tool: "Read", timestamp: DateTime.utc_now()}}
      )

      assert_receive {:session_update, ^id, %{status: :working}}, 1000

      # 2. JSONL: tool_result → still working (idle timer started)
      send(
        pid,
        {:parser_event, id, %{type: :tool_result, tool: "Read", timestamp: DateTime.utc_now()}}
      )

      # 3. PTY: prompt rendered between tool calls — should be ignored
      send(pid, {:pty_output, id, "\r\n\e[1m❯\e[0m "})

      # Should NOT go idle — JSONL turn is active
      refute_receive {:session_update, ^id, %{status: :idle}}, 300

      # 4. JSONL: next tool_call processes normally
      send(
        pid,
        {:parser_event, id, %{type: :tool_call, tool: "Grep", timestamp: DateTime.utc_now()}}
      )

      state = :sys.get_state(pid)
      assert state.status == :working
    end

    test "PTY prompt works when no JSONL turn is active", %{
      session_id: id,
      pid: pid
    } do
      # Start working via assistant_response (sets jsonl_turn_active)
      send(pid, {:parser_event, id, %{type: :assistant_response, timestamp: DateTime.utc_now()}})
      assert_receive {:session_update, ^id, %{status: :working}}, 1000

      # End the turn (clears jsonl_turn_active)
      send(pid, {:parser_event, id, %{type: :turn_end, timestamp: DateTime.utc_now()}})
      assert_receive {:session_update, ^id, %{status: :idle}}, 500

      # Start working again without JSONL (simulates non-Claude session)
      # Use :sys.replace_state to set working without setting jsonl_turn_active
      :sys.replace_state(pid, fn state -> %{state | status: :working} end)

      # PTY prompt should work since jsonl_turn_active is false
      send(pid, {:pty_output, id, "\r\n❯ "})
      assert_receive {:session_update, ^id, %{status: :idle}}, 500
    end

    test "turn_end clears jsonl_turn_active so PTY prompt works after", %{
      session_id: id,
      pid: pid
    } do
      # JSONL turn: tool_call → turn_end
      send(
        pid,
        {:parser_event, id, %{type: :tool_call, tool: "Read", timestamp: DateTime.utc_now()}}
      )

      assert_receive {:session_update, ^id, %{status: :working}}, 1000

      send(pid, {:parser_event, id, %{type: :turn_end, timestamp: DateTime.utc_now()}})
      assert_receive {:session_update, ^id, %{status: :idle}}, 500

      # New working state without JSONL
      :sys.replace_state(pid, fn state -> %{state | status: :working} end)

      # PTY prompt should now work (turn is over)
      send(pid, {:pty_output, id, "\r\n❯ "})
      assert_receive {:session_update, ^id, %{status: :idle}}, 500
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
