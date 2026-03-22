defmodule Sam.LLM.Ollama do
  @moduledoc """
  Ollama integration for session summarization.

  Provides LLM-powered summaries via local Ollama, with pure-function
  heuristic fallback when Ollama is unavailable.
  """

  @default_base_url "http://localhost:11434"
  @preferred_models ["gemma3:4b", "gemma3:1b"]
  @max_label_length 120

  @prompt_preamble """
  Summarize this AI coding agent's recent activity in 1 short sentence for a dashboard.
  Be precise: Read = looked at, Edit/Write = changed, Bash = ran command, Grep/Glob = searched.
  Do NOT say "updated" or "modified" unless you see Edit or Write. Say "reviewed" or "read" for Read.

  Recent activity:
  """

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Check if Ollama is reachable and find a preferred model.
  Returns `{:ok, model_name}` or `{:error, :unavailable}`.
  """
  def check_availability(opts \\ []) do
    base_url = Keyword.get(opts, :base_url, @default_base_url)

    case Req.get("#{base_url}/api/tags", receive_timeout: 3_000, retry: false) do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        names = Enum.map(models, & &1["name"])
        find_preferred_model(names)

      _ ->
        {:error, :unavailable}
    end
  end

  @doc """
  Summarize a batch of parser events using Ollama.
  Returns `{:ok, summary}` or `{:error, reason}`.
  """
  def summarize(events, model, opts \\ []) do
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    prompt = @prompt_preamble <> format_events_for_prompt(events) <> "\n\nSummary:"

    body = %{
      model: model,
      prompt: prompt,
      stream: false,
      num_predict: 60,
      temperature: 0.3
    }

    case Req.post("#{base_url}/api/generate",
           json: body,
           receive_timeout: 5_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"response" => text}}} ->
        {:ok, String.trim(text)}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, "API error #{status}: #{inspect(resp_body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generate a heuristic label from buffered events (no LLM needed).
  Uses the most recent tool_call event's description, file, or tool name.
  """
  def heuristic_label(events) when is_list(events) do
    # Prefer the most recent tool_call with a description
    tool_event =
      events
      |> Enum.filter(&(&1.type == :tool_call))
      |> List.last()

    case tool_event do
      nil ->
        # No tool calls — check for other activity
        cond do
          Enum.any?(events, &(&1.type == :assistant_response)) -> "Responding..."
          Enum.any?(events, &(&1.type == :user_prompt)) -> "Processing prompt..."
          true -> "Agent is working..."
        end

      event ->
        label_from_event(event)
    end
  end

  @doc """
  Format parser events into a text prompt for the LLM.
  """
  def format_events_for_prompt(events) when is_list(events) do
    events
    |> Enum.map(&format_event/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp find_preferred_model(available_names) do
    Enum.find_value(@preferred_models, {:error, :unavailable}, fn preferred ->
      if Enum.any?(available_names, &String.starts_with?(&1, preferred)) do
        {:ok, preferred}
      end
    end)
  end

  defp label_from_event(event) do
    desc = Map.get(event, :description)
    file = Map.get(event, :file)
    tool = Map.get(event, :tool, "unknown")

    cond do
      is_binary(desc) and desc != "" ->
        String.slice(desc, 0, @max_label_length)

      is_binary(file) and file != "" ->
        "#{tool} #{file}" |> String.slice(0, @max_label_length)

      true ->
        tool
    end
  end

  defp format_event(%{type: type, tool: tool} = event)
       when type in [:tool_call, :pre_tool_call] do
    desc = Map.get(event, :description, "")
    file = Map.get(event, :file, "")

    parts =
      ["[#{tool}]", desc, file]
      |> Enum.reject(&(&1 == "" or is_nil(&1)))

    Enum.join(parts, " ")
  end

  defp format_event(%{type: :tool_result, tool: tool}) do
    "[#{tool}] completed"
  end

  defp format_event(%{type: :assistant_response, text: text})
       when is_binary(text) and text != "" do
    "Claude: #{String.slice(text, 0, 150)}"
  end

  defp format_event(%{type: :assistant_response}) do
    "Claude responded"
  end

  defp format_event(%{type: :user_prompt, text: text})
       when is_binary(text) and text != "" do
    "User: #{String.slice(text, 0, 150)}"
  end

  defp format_event(%{type: :user_prompt}) do
    "User submitted a prompt"
  end

  defp format_event(%{type: :turn_end}) do
    "Turn completed"
  end

  defp format_event(%{type: :activity, lines: lines}) when is_list(lines) do
    lines |> Enum.take(5) |> Enum.join(" | ")
  end

  defp format_event(_), do: ""
end
