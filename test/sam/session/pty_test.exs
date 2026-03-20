defmodule Sam.Session.PTYTest do
  use ExUnit.Case, async: false

  describe "start_link/1" do
    test "spawns a shell and receives output via PubSub" do
      Phoenix.PubSub.subscribe(Sam.PubSub, "session:test-pty-1")

      {:ok, pid} =
        Sam.Session.PTY.start_link(%{
          command: ["/bin/bash", "-l"],
          session_id: "test-pty-1"
        })

      Sam.Session.PTY.send_input(pid, "echo sam_test_marker\n")

      # Collect output until we see our marker
      assert_pty_output_contains("sam_test_marker", 5000)

      Sam.Session.PTY.stop(pid)
    end
  end

  describe "resize/3" do
    test "sends resize command without crashing" do
      {:ok, pid} =
        Sam.Session.PTY.start_link(%{
          command: ["/bin/bash", "-l"],
          session_id: "test-pty-2"
        })

      assert :ok = Sam.Session.PTY.resize(pid, 120, 40)
      # Give it a moment, then verify process is still alive
      Process.sleep(100)
      assert Process.alive?(pid)

      Sam.Session.PTY.stop(pid)
    end
  end

  defp assert_pty_output_contains(marker, timeout) do
    assert_pty_output_contains(marker, timeout, "")
  end

  defp assert_pty_output_contains(marker, timeout, acc) do
    receive do
      {:pty_output, _, data} ->
        acc = acc <> data

        if String.contains?(acc, marker) do
          :ok
        else
          assert_pty_output_contains(marker, timeout, acc)
        end
    after
      timeout -> flunk("Timed out waiting for #{marker} in PTY output. Got: #{inspect(acc)}")
    end
  end
end
