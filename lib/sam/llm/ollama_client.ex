defmodule Sam.LLM.OllamaClient do
  @moduledoc """
  Stateless HTTP client for the local Ollama REST API.

  Used for LLM-powered session summarization via Gemma 4B.
  """

  @default_base_url "http://localhost:11434"
  @default_model "gemma3:4b"
  @content_cap 2000
  @generate_timeout 15_000
  @pull_timeout 300_000

  @prompt_preamble """
  You are summarizing an AI coding agent's activity for a dashboard.
  In 1-2 lines, tell the user what just happened and whether they need to take action.
  Don't describe tools or process — describe outcomes and decisions.
  Be specific about file names and what changed.

  Conversation:
  """

  # ── Public API ───────────────────────────────────────────────────────────────

  @doc """
  Health check against GET /api/tags. Returns true if Ollama is reachable.
  """
  def available?(opts \\ []) do
    base_url = Keyword.get(opts, :base_url, @default_base_url)

    case Req.get("#{base_url}/api/tags", receive_timeout: 3_000, retry: false) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end

  @doc """
  Sends conversation turns to Gemma via POST /api/generate.
  Returns `{:ok, summary}` or `{:error, reason}`.

  On 404 (model not found), fires a background pull and returns `{:error, :model_pulling}`.
  """
  def summarize(turns, opts \\ []) when is_list(turns) do
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    model = Keyword.get(opts, :model, @default_model)
    prompt = build_prompt(turns)

    body = %{
      model: model,
      prompt: prompt,
      stream: false,
      num_predict: 100,
      temperature: 0.3
    }

    case Req.post("#{base_url}/api/generate",
           json: body,
           receive_timeout: @generate_timeout,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"response" => text}}} ->
        {:ok, String.trim(text)}

      {:ok, %{status: 404}} ->
        pull_model_async(base_url, model)
        {:error, :model_pulling}

      {:ok, %{status: status, body: body}} ->
        {:error, "API error #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Builds the prompt string from a list of `%{role: string, content: string}` turns.
  """
  def build_prompt(turns) do
    conversation =
      turns
      |> Enum.map(fn %{role: role, content: content} -> "#{role}: #{content}" end)
      |> Enum.join("\n")

    @prompt_preamble <> conversation <> "\n\nSummary:"
  end

  @doc """
  Reads a JSONL file, extracts the last `max_turns` conversation turns.
  Returns a list of `%{role: string, content: string}` maps.
  Caps total content at ~2000 chars.
  """
  def extract_turns(jsonl_path, max_turns \\ 10) do
    with {:ok, content} <- File.read(jsonl_path) do
      content
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&parse_jsonl_line/1)
      |> Enum.take(-max_turns)
      |> cap_content(@content_cap)
    else
      _ -> []
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp parse_jsonl_line(line) do
    case Jason.decode(line) do
      {:ok, %{"message" => %{"role" => role, "content" => content}}} ->
        [%{role: role, content: extract_content(content)}]

      _ ->
        []
    end
  end

  # Content may be a plain string or a list of blocks
  defp extract_content(content) when is_binary(content), do: content

  defp extract_content(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      %{"type" => "tool_use", "name" => name} -> "[#{name}]"
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp extract_content(_), do: ""

  # Cap total content across all turns to avoid huge prompts.
  # Trims from the front (oldest) first.
  defp cap_content(turns, limit) do
    total = turns |> Enum.map(& &1.content) |> Enum.join() |> String.length()

    if total <= limit do
      turns
    else
      turns
      |> Enum.reduce_while({[], 0}, fn turn, {acc, chars} ->
        new_chars = chars + String.length(turn.content)

        if new_chars <= limit do
          {:cont, {acc ++ [turn], new_chars}}
        else
          # Truncate this turn to fill remaining budget
          remaining = limit - chars

          if remaining > 0 do
            truncated = %{turn | content: String.slice(turn.content, 0, remaining)}
            {:halt, {acc ++ [truncated], limit}}
          else
            {:halt, {acc, chars}}
          end
        end
      end)
      |> elem(0)
    end
  end

  defp pull_model_async(base_url, model) do
    Task.start(fn ->
      Req.post("#{base_url}/api/pull",
        json: %{name: model},
        receive_timeout: @pull_timeout
      )
    end)
  end
end
