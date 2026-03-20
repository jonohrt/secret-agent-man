defmodule Sam.Hooks.ClaudeCodeHooks do
  @settings_path Path.join(System.user_home!(), ".claude/settings.json")

  def check_and_prompt do
    case File.read(@settings_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, settings} ->
            if has_sam_hooks?(settings), do: :already_registered, else: :needs_registration

          _ ->
            :error
        end

      {:error, :enoent} ->
        :no_settings_file

      {:error, _} ->
        :error
    end
  end

  def register_hooks! do
    content =
      case File.read(@settings_path) do
        {:ok, c} -> c
        {:error, :enoent} -> "{}"
      end

    settings = Jason.decode!(content)
    hooks = Map.get(settings, "hooks", %{})

    sam_hook = %{
      "type" => "command",
      "command" =>
        "curl -s -X POST http://localhost:4000/api/hooks -H 'Content-Type: application/json' -d '{\"event\":\"$EVENT\",\"session_id\":\"$SESSION_ID\"}'"
    }

    post_tool = Map.get(hooks, "postToolUse", [])
    updated_hooks = Map.put(hooks, "postToolUse", post_tool ++ [sam_hook])
    updated_settings = Map.put(settings, "hooks", updated_hooks)

    File.write!(@settings_path, Jason.encode!(updated_settings, pretty: true))
    :ok
  end

  defp has_sam_hooks?(settings) do
    settings
    |> Map.get("hooks", %{})
    |> Enum.any?(fn {_key, hooks} ->
      Enum.any?(List.wrap(hooks), fn hook ->
        is_map(hook) && String.contains?(Map.get(hook, "command", ""), "localhost:4000/api/hooks")
      end)
    end)
  end
end
