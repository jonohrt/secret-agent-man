defmodule Sam.Session.SummarizerTest do
  use ExUnit.Case, async: false

  describe "summarization" do
    test "buffers events and produces summaries on decision points" do
      Phoenix.PubSub.subscribe(Sam.PubSub, "session:test-sum-1")

      {:ok, pid} = Sam.Session.Summarizer.start_link(%{
        session_id: "test-sum-1",
        debounce_ms: 50
      })

      # Push activity events
      Sam.Session.Summarizer.push_event(pid, %{
        type: :activity,
        lines: ["Searching codebase for auth handler", "Found 3 files matching"],
        timestamp: DateTime.utc_now()
      })

      # Push a decision point (triggers summary)
      Sam.Session.Summarizer.push_event(pid, %{
        type: :tool_call,
        tool: "Edit",
        file: "src/auth.ts",
        timestamp: DateTime.utc_now()
      })

      # Should receive a summary (using fallback since no API key)
      assert_receive {:summary, "test-sum-1", %{summary: summary, raw_events: events}}, 2000
      assert is_binary(summary)
      assert length(events) == 2
    end

    test "without API key, falls back to joining lines" do
      Phoenix.PubSub.subscribe(Sam.PubSub, "session:test-sum-2")

      {:ok, pid} = Sam.Session.Summarizer.start_link(%{
        session_id: "test-sum-2",
        debounce_ms: 50
      })

      Sam.Session.Summarizer.push_event(pid, %{
        type: :activity,
        lines: ["line one", "line two"],
        timestamp: DateTime.utc_now()
      })

      Sam.Session.Summarizer.push_event(pid, %{
        type: :input_needed,
        timestamp: DateTime.utc_now()
      })

      assert_receive {:summary, "test-sum-2", %{summary: summary}}, 2000
      assert String.contains?(summary, "line one")
    end
  end
end
