defmodule Sam.Session.SummarizerTest do
  use ExUnit.Case, async: false

  describe "JSONL-based summarization" do
    @tag :tmp_dir
    test "summarizes from JSONL turns on decision point", %{tmp_dir: tmp_dir} do
      session_id = "test-sum-jsonl-#{System.unique_integer([:positive])}"
      jsonl_path = Path.join(tmp_dir, "session.jsonl")

      records =
        [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => [
                %{"type" => "text", "text" => "I'll fix the login bug by updating auth.ex"}
              ]
            }
          },
          %{
            "message" => %{
              "role" => "assistant",
              "content" => [
                %{"type" => "text", "text" => "Running tests to verify the fix"},
                %{"type" => "tool_use", "name" => "Bash", "id" => "t1", "input" => %{}}
              ]
            }
          }
        ]
        |> Enum.map(&Jason.encode!/1)

      File.write!(jsonl_path, Enum.join(records, "\n") <> "\n")

      Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

      {:ok, pid} =
        Sam.Session.Summarizer.start_link(%{
          session_id: session_id,
          debounce_ms: 50
        })

      send(pid, {:journal_found, jsonl_path})

      Sam.Session.Summarizer.push_event(pid, %{
        type: :tool_call,
        tool: "Edit",
        timestamp: DateTime.utc_now()
      })

      assert_receive {:summary, ^session_id, %{summary: summary}}, 5000
      assert is_binary(summary)
      assert String.length(summary) > 0
    end

    @tag :tmp_dir
    test "falls back to last assistant text when Ollama unavailable", %{tmp_dir: tmp_dir} do
      session_id = "test-sum-fallback-#{System.unique_integer([:positive])}"
      jsonl_path = Path.join(tmp_dir, "session.jsonl")

      record =
        Jason.encode!(%{
          "message" => %{
            "role" => "assistant",
            "content" => [
              %{
                "type" => "text",
                "text" => "I fixed the authentication bug in login.ex by adding a nil check"
              }
            ]
          }
        })

      File.write!(jsonl_path, record <> "\n")

      Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

      {:ok, pid} =
        Sam.Session.Summarizer.start_link(%{
          session_id: session_id,
          debounce_ms: 50,
          ollama_opts: [base_url: "http://localhost:1"]
        })

      send(pid, {:journal_found, jsonl_path})

      Sam.Session.Summarizer.push_event(pid, %{
        type: :tool_call,
        tool: "Read",
        timestamp: DateTime.utc_now()
      })

      assert_receive {:summary, ^session_id, %{summary: summary}}, 5000
      assert is_binary(summary)
      assert String.length(summary) > 0
    end

    test "produces no summary when no JSONL path available" do
      session_id = "test-sum-nopath-#{System.unique_integer([:positive])}"

      Phoenix.PubSub.subscribe(Sam.PubSub, "session:#{session_id}")

      {:ok, pid} =
        Sam.Session.Summarizer.start_link(%{
          session_id: session_id,
          debounce_ms: 50
        })

      Sam.Session.Summarizer.push_event(pid, %{
        type: :tool_call,
        tool: "Read",
        timestamp: DateTime.utc_now()
      })

      refute_receive {:summary, ^session_id, _}, 500
    end
  end
end
