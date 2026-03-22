defmodule Sam.Session.SummarizerTest do
  use ExUnit.Case, async: false

  describe "heuristic summarization (no Ollama)" do
    test "produces heuristic label on decision point event" do
      session_id = "test-sum-heur-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

      {:ok, pid} =
        Sam.Session.Summarizer.start_link(%{
          session_id: session_id,
          debounce_ms: 50,
          ollama_opts: [base_url: "http://localhost:1"]
        })

      Sam.Session.Summarizer.push_event(pid, %{
        type: :tool_call,
        tool: "Edit",
        description: "Fixing auth bug",
        file: "lib/auth.ex",
        timestamp: DateTime.utc_now()
      })

      assert_receive {:summary, ^session_id, payload}, 5000
      assert payload.text == "Fixing auth bug"
      assert payload.tool_count == 1
      assert %DateTime{} = payload.timestamp
    end

    test "counts multiple tool_call events in a batch" do
      session_id = "test-sum-count-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

      {:ok, pid} =
        Sam.Session.Summarizer.start_link(%{
          session_id: session_id,
          debounce_ms: 50,
          ollama_opts: [base_url: "http://localhost:1"]
        })

      Sam.Session.Summarizer.push_event(pid, %{
        type: :tool_call,
        tool: "Read",
        description: "reading config",
        timestamp: DateTime.utc_now()
      })

      Sam.Session.Summarizer.push_event(pid, %{
        type: :tool_call,
        tool: "Edit",
        description: "fixing server",
        timestamp: DateTime.utc_now()
      })

      Sam.Session.Summarizer.push_event(pid, %{
        type: :tool_call,
        tool: "Bash",
        description: "running tests",
        timestamp: DateTime.utc_now()
      })

      assert_receive {:summary, ^session_id, payload}, 5000
      assert payload.tool_count == 3
      assert payload.text == "running tests"
    end

    test "uses file path fallback when description is nil" do
      session_id = "test-sum-file-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

      {:ok, pid} =
        Sam.Session.Summarizer.start_link(%{
          session_id: session_id,
          debounce_ms: 50,
          ollama_opts: [base_url: "http://localhost:1"]
        })

      Sam.Session.Summarizer.push_event(pid, %{
        type: :tool_call,
        tool: "Read",
        description: nil,
        file: "lib/sam/server.ex",
        timestamp: DateTime.utc_now()
      })

      assert_receive {:summary, ^session_id, payload}, 5000
      assert payload.text == "Read lib/sam/server.ex"
    end

    test "no summary when buffer is empty after debounce" do
      session_id = "test-sum-empty-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

      {:ok, _pid} =
        Sam.Session.Summarizer.start_link(%{
          session_id: session_id,
          debounce_ms: 50,
          ollama_opts: [base_url: "http://localhost:1"]
        })

      refute_receive {:summary, ^session_id, _}, 200
    end

    test "receives events via PubSub parser_event" do
      session_id = "test-sum-pubsub-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

      {:ok, _pid} =
        Sam.Session.Summarizer.start_link(%{
          session_id: session_id,
          debounce_ms: 50,
          ollama_opts: [base_url: "http://localhost:1"]
        })

      # Summarizer subscribes to session:#{id} and receives parser_events
      Phoenix.PubSub.broadcast(
        Sam.PubSub,
        "session:#{session_id}",
        {:parser_event, session_id,
         %{
           type: :tool_call,
           tool: "Grep",
           description: "searching logs",
           timestamp: DateTime.utc_now()
         }}
      )

      assert_receive {:summary, ^session_id, %{text: "searching logs"}}, 5000
    end
  end

  describe "ollama mode detection" do
    test "state tracks ollama_model as nil when unavailable" do
      session_id = "test-sum-mode-#{System.unique_integer([:positive])}"

      {:ok, pid} =
        Sam.Session.Summarizer.start_link(%{
          session_id: session_id,
          debounce_ms: 50,
          ollama_opts: [base_url: "http://localhost:1"]
        })

      state = :sys.get_state(pid)
      assert state.ollama_model == nil
    end
  end
end
