defmodule Sam.Session.ParserTest do
  use ExUnit.Case, async: true

  alias Sam.Session.Parser

  describe "strip_ansi/1" do
    test "strips ANSI escape sequences" do
      raw = "\e[32mhello\e[0m world"
      assert Parser.strip_ansi(raw) == "hello world"
    end

    test "strips OSC sequences" do
      raw = "\e]0;window title\e\\plain text"
      assert Parser.strip_ansi(raw) == "plain text"
    end

    test "returns plain text unchanged" do
      assert Parser.strip_ansi("hello world") == "hello world"
    end
  end

  describe "input_needed?/1" do
    test "detects various input prompt patterns" do
      assert Parser.input_needed?("? Allow Read tool on file.txt (y/N)")
      assert Parser.input_needed?("Do you want to proceed? [y/N]")
      assert Parser.input_needed?("Press enter to continue")
      assert Parser.input_needed?("Continue?")
      assert Parser.input_needed?("Proceed?")
    end

    test "does not flag normal output" do
      refute Parser.input_needed?("Compiling 5 files...")
      refute Parser.input_needed?("Done.")
      refute Parser.input_needed?("Running tests...")
    end

    test "detects patterns even with ANSI sequences" do
      assert Parser.input_needed?("\e[32m? Allow\e[0m Read tool [y/N]")
    end
  end

  describe "parse_hook_event/1" do
    test "converts map to structured event" do
      event = %{
        "event" => "tool_call",
        "tool" => "Edit",
        "file" => "src/auth.ts",
        "session_id" => "abc"
      }

      parsed = Parser.parse_hook_event(event)
      assert parsed.type == :tool_call
      assert parsed.tool == "Edit"
      assert parsed.file == "src/auth.ts"
      assert parsed.session_id == "abc"
      assert %DateTime{} = parsed.timestamp
    end
  end

  describe "GenServer buffering" do
    test "buffers output and emits activity event on quiescence" do
      session_id = "test-parser-quiescence-#{:erlang.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

      {:ok, pid} = Parser.start_link(%{session_id: session_id, quiescence_ms: 100})

      Parser.push_output(pid, "Searching for files...\n")
      Parser.push_output(pid, "Found 3 matches\n")

      assert_receive {:parser_event, ^session_id, %{type: :activity, lines: lines}}, 500
      assert length(lines) == 2
      assert "Searching for files..." in lines
      assert "Found 3 matches" in lines
    end

    test "broadcasts input_needed event immediately on matching output" do
      session_id = "test-parser-input-#{:erlang.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

      {:ok, pid} = Parser.start_link(%{session_id: session_id, quiescence_ms: 5_000})

      Parser.push_output(pid, "? Allow Read tool on file.txt [y/N]")

      assert_receive {:parser_event, ^session_id, %{type: :input_needed}}, 500
    end
  end
end
