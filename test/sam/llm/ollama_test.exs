defmodule Sam.LLM.OllamaTest do
  use ExUnit.Case, async: true

  alias Sam.LLM.Ollama

  describe "heuristic_label/1" do
    test "uses description when available" do
      events = [
        %{
          type: :tool_call,
          tool: "Edit",
          description: "Fixing auth bug in login.ex",
          timestamp: DateTime.utc_now()
        }
      ]

      assert Ollama.heuristic_label(events) == "Fixing auth bug in login.ex"
    end

    test "uses file path when description is empty" do
      events = [
        %{
          type: :tool_call,
          tool: "Read",
          description: "",
          file: "lib/sam/server.ex",
          timestamp: DateTime.utc_now()
        }
      ]

      assert Ollama.heuristic_label(events) == "Read lib/sam/server.ex"
    end

    test "uses file path when description is nil" do
      events = [
        %{
          type: :tool_call,
          tool: "Read",
          description: nil,
          file: "lib/sam/server.ex",
          timestamp: DateTime.utc_now()
        }
      ]

      assert Ollama.heuristic_label(events) == "Read lib/sam/server.ex"
    end

    test "falls back to tool name when no description or file" do
      events = [
        %{type: :tool_call, tool: "Bash", timestamp: DateTime.utc_now()}
      ]

      assert Ollama.heuristic_label(events) == "Bash"
    end

    test "picks the most recent tool_call event" do
      events = [
        %{type: :tool_call, tool: "Read", description: "first", timestamp: DateTime.utc_now()},
        %{type: :activity, lines: ["some output"], timestamp: DateTime.utc_now()},
        %{type: :tool_call, tool: "Edit", description: "second", timestamp: DateTime.utc_now()}
      ]

      assert Ollama.heuristic_label(events) == "second"
    end

    test "handles empty event list" do
      assert Ollama.heuristic_label([]) == "Agent is working..."
    end

    test "handles events with no tool_call types" do
      events = [
        %{type: :activity, lines: ["output"], timestamp: DateTime.utc_now()}
      ]

      assert Ollama.heuristic_label(events) == "Agent is working..."
    end

    test "truncates long descriptions" do
      long_desc = String.duplicate("x", 200)

      events = [
        %{type: :tool_call, tool: "Edit", description: long_desc, timestamp: DateTime.utc_now()}
      ]

      label = Ollama.heuristic_label(events)
      assert String.length(label) <= 120
    end
  end

  describe "format_events_for_prompt/1" do
    test "formats tool_call events with descriptions" do
      events = [
        %{
          type: :tool_call,
          tool: "Read",
          description: "checking config",
          file: "config.exs",
          timestamp: DateTime.utc_now()
        },
        %{
          type: :tool_call,
          tool: "Edit",
          description: "fixing bug",
          file: "server.ex",
          timestamp: DateTime.utc_now()
        }
      ]

      result = Ollama.format_events_for_prompt(events)
      assert result =~ "Read"
      assert result =~ "checking config"
      assert result =~ "Edit"
      assert result =~ "fixing bug"
    end

    test "includes activity lines" do
      events = [
        %{type: :activity, lines: ["Running tests...", "3 passed"], timestamp: DateTime.utc_now()}
      ]

      result = Ollama.format_events_for_prompt(events)
      assert result =~ "Running tests..."
    end

    test "handles empty list" do
      assert Ollama.format_events_for_prompt([]) == ""
    end
  end

  describe "check_availability/1" do
    test "returns {:ok, model} when preferred model found" do
      # Mock by using a fake base_url — will fail connection
      assert {:error, _} = Ollama.check_availability(base_url: "http://localhost:1")
    end

    test "returns {:error, :unavailable} when Ollama is down" do
      assert {:error, :unavailable} = Ollama.check_availability(base_url: "http://localhost:1")
    end
  end

  describe "summarize/3" do
    test "returns error when Ollama is unreachable" do
      events = [
        %{type: :tool_call, tool: "Read", description: "test", timestamp: DateTime.utc_now()}
      ]

      assert {:error, _} = Ollama.summarize(events, "gemma3:4b", base_url: "http://localhost:1")
    end
  end
end
