defmodule Sam.LLM.Client do
  @default_model "claude-haiku-4-5-20251001"

  def summarize(lines, opts \\ []) when is_list(lines) do
    api_key = Application.get_env(:sam, :anthropic_api_key) || System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) do
      {:ok, Enum.join(lines, " | ")}
    else
      model = Keyword.get(opts, :model, @default_model)

      prompt = """
      Summarize what happened in this sequence of AI coding agent actions in one sentence.
      Focus on the outcome, not the process. Be concise.

      Actions:
      #{Enum.join(lines, "\n")}
      """

      body = %{
        model: model,
        max_tokens: 150,
        messages: [%{role: "user", content: prompt}]
      }

      case Req.post("https://api.anthropic.com/v1/messages",
             json: body,
             headers: [
               {"x-api-key", api_key},
               {"anthropic-version", "2023-06-01"}
             ]
           ) do
        {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
          {:ok, String.trim(text)}

        {:ok, %{status: status, body: body}} ->
          {:error, "API error #{status}: #{inspect(body)}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
