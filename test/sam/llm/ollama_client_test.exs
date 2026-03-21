defmodule Sam.LLM.OllamaClientTest do
  use ExUnit.Case, async: true

  alias Sam.LLM.OllamaClient

  # ── available?/0 ────────────────────────────────────────────────────────────

  @tag :integration
  test "available?/0 returns a boolean" do
    result = OllamaClient.available?()
    assert is_boolean(result)
  end

  # ── summarize/2 ─────────────────────────────────────────────────────────────

  test "summarize/2 returns {:error, _} when Ollama is unreachable" do
    turns = [%{role: "user", content: "hello"}]
    assert {:error, _reason} = OllamaClient.summarize(turns, base_url: "http://localhost:1")
  end

  # ── build_prompt/1 ──────────────────────────────────────────────────────────

  test "build_prompt/1 includes the system preamble" do
    prompt = OllamaClient.build_prompt([])
    assert String.contains?(prompt, "summarizing an AI coding agent")
    assert String.contains?(prompt, "Summary:")
  end

  test "build_prompt/1 includes turn content formatted as role: content" do
    turns = [
      %{role: "user", content: "Can you read auth.ex?"},
      %{role: "assistant", content: "Sure, reading now."}
    ]

    prompt = OllamaClient.build_prompt(turns)
    assert String.contains?(prompt, "user: Can you read auth.ex?")
    assert String.contains?(prompt, "assistant: Sure, reading now.")
  end

  test "build_prompt/1 works with empty turns list" do
    prompt = OllamaClient.build_prompt([])
    assert is_binary(prompt)
    assert String.contains?(prompt, "Summary:")
  end

  # ── extract_turns/2 ─────────────────────────────────────────────────────────

  @tag :tmp_dir
  test "extract_turns/2 reads last N turns from a JSONL file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "session.jsonl")

    lines = [
      Jason.encode!(%{type: "user", message: %{role: "user", content: "First message"}}),
      Jason.encode!(%{type: "assistant", message: %{role: "assistant", content: "First reply"}}),
      Jason.encode!(%{type: "user", message: %{role: "user", content: "Second message"}}),
      Jason.encode!(%{type: "assistant", message: %{role: "assistant", content: "Second reply"}}),
      Jason.encode!(%{type: "user", message: %{role: "user", content: "Third message"}}),
      Jason.encode!(%{
        type: "assistant",
        message: %{role: "assistant", content: "Third reply"}
      })
    ]

    File.write!(path, Enum.join(lines, "\n") <> "\n")

    turns = OllamaClient.extract_turns(path, 4)
    assert length(turns) == 4
    # Should be the last 4
    assert List.last(turns).content == "Third reply"
  end

  @tag :tmp_dir
  test "extract_turns/2 caps total content at ~2000 chars", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "session.jsonl")

    # Each message is ~600 chars — 4 of them exceed 2000
    long_content = String.duplicate("x", 600)

    lines =
      Enum.map(1..5, fn i ->
        Jason.encode!(%{
          type: "user",
          message: %{role: "user", content: "#{long_content}_#{i}"}
        })
      end)

    File.write!(path, Enum.join(lines, "\n") <> "\n")

    turns = OllamaClient.extract_turns(path, 10)
    total_chars = turns |> Enum.map(& &1.content) |> Enum.join() |> String.length()
    assert total_chars <= 2100, "Total content #{total_chars} chars exceeds cap"
  end

  @tag :tmp_dir
  test "extract_turns/2 extracts tool names from tool_use content blocks", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "session.jsonl")

    lines = [
      Jason.encode!(%{
        type: "assistant",
        message: %{
          role: "assistant",
          content: [
            %{type: "text", text: "Let me read that file."},
            %{type: "tool_use", name: "Read"},
            %{type: "tool_use", name: "Edit"}
          ]
        }
      })
    ]

    File.write!(path, Enum.join(lines, "\n") <> "\n")

    turns = OllamaClient.extract_turns(path, 10)
    assert length(turns) == 1
    [turn] = turns
    assert String.contains?(turn.content, "Let me read that file.")
    assert String.contains?(turn.content, "[Read]")
    assert String.contains?(turn.content, "[Edit]")
  end

  @tag :tmp_dir
  test "extract_turns/2 returns empty list for non-existent file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "missing.jsonl")
    assert OllamaClient.extract_turns(path) == []
  end

  @tag :tmp_dir
  test "extract_turns/2 skips records without message.role", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "session.jsonl")

    lines = [
      Jason.encode!(%{type: "summary", data: "something"}),
      Jason.encode!(%{type: "user", message: %{role: "user", content: "Hello"}}),
      "{invalid json"
    ]

    File.write!(path, Enum.join(lines, "\n") <> "\n")

    turns = OllamaClient.extract_turns(path)
    assert length(turns) == 1
    assert hd(turns).role == "user"
  end
end
