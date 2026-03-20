defmodule Sam.Session.ServerTest do
  use ExUnit.Case, async: false

  describe "session lifecycle" do
    test "creates a session via GroupSupervisor" do
      session_id = "test-server-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(Sam.PubSub, "sessions:ui")
      Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

      {:ok, _sup_pid} = Sam.Session.GroupSupervisor.start_session(%{
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
