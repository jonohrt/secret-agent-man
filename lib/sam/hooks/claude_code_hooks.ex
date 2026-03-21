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

    # Hooks receive JSON on stdin with tool_name and tool_input.
    # We parse stdin to extract meaningful descriptions for the activity feed.
    hook_script = hook_script_path()
    File.write!(hook_script, hook_script_content())
    File.chmod!(hook_script, 0o755)

    pre_hook_entry = %{
      "hooks" => [
        %{
          "type" => "command",
          "command" => "#{hook_script} pre_tool_call"
        }
      ]
    }

    post_hook_entry = %{
      "hooks" => [
        %{
          "type" => "command",
          "command" => "#{hook_script} post_tool_call"
        }
      ]
    }

    pre_tool = Map.get(hooks, "PreToolUse", [])
    post_tool = Map.get(hooks, "PostToolUse", [])

    updated_hooks =
      hooks
      |> Map.put("PreToolUse", pre_tool ++ [pre_hook_entry])
      |> Map.put("PostToolUse", post_tool ++ [post_hook_entry])

    updated_settings = Map.put(settings, "hooks", updated_hooks)

    File.write!(@settings_path, Jason.encode!(updated_settings, pretty: true))
    :ok
  end

  defp hook_script_path do
    Path.join(System.user_home!(), ".claude/hooks/sam-hook.sh")
  end

  defp hook_script_content do
    ~S"""
    #!/bin/bash
    # SAM hook — reads Claude Code event JSON from stdin, posts to SAM
    EVENT_TYPE="$1"
    SESSION_ID="${SAM_SESSION_ID:-unknown}"

    if [ "$SESSION_ID" = "unknown" ] || [ -z "$SESSION_ID" ]; then
      exit 0
    fi

    # Read JSON from stdin
    INPUT=$(cat)

    # Extract tool name and a useful description from tool_input
    TOOL=$(echo "$INPUT" | jq -r '.tool_name // "unknown"' 2>/dev/null)

    # Build a human-readable description based on tool type
    case "$TOOL" in
      Bash)
        DESC=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null | head -c 120)
        ;;
      Read)
        DESC=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
        ;;
      Edit)
        DESC=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
        ;;
      Write)
        DESC=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
        ;;
      Grep)
        PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // ""' 2>/dev/null)
        DESC="/$PATTERN/"
        ;;
      Glob)
        DESC=$(echo "$INPUT" | jq -r '.tool_input.pattern // ""' 2>/dev/null)
        ;;
      Agent)
        DESC=$(echo "$INPUT" | jq -r '.tool_input.description // .tool_input.prompt // ""' 2>/dev/null | head -c 120)
        ;;
      WebSearch)
        DESC=$(echo "$INPUT" | jq -r '.tool_input.query // ""' 2>/dev/null | head -c 120)
        ;;
      *)
        DESC=""
        ;;
    esac

    # Post to SAM
    curl -s -X POST http://localhost:4000/api/hooks \
      -H 'Content-Type: application/json' \
      -d "$(jq -n --arg event "$EVENT_TYPE" --arg sid "$SESSION_ID" --arg tool "$TOOL" --arg desc "$DESC" \
        '{event: $event, session_id: $sid, tool: $tool, description: $desc}')" \
      > /dev/null 2>&1

    exit 0
    """
  end

  defp has_sam_hooks?(settings) do
    settings
    |> Map.get("hooks", %{})
    |> Enum.any?(fn {_key, hook_entries} ->
      Enum.any?(List.wrap(hook_entries), fn entry ->
        hooks = if is_map(entry), do: Map.get(entry, "hooks", []), else: []

        Enum.any?(List.wrap(hooks), fn hook ->
          is_map(hook) &&
            String.contains?(Map.get(hook, "command", ""), "sam-hook.sh")
        end)
      end)
    end)
  end
end
