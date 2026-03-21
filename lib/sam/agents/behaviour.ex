defmodule Sam.Agents.Behaviour do
  @callback spawn_command(workdir :: String.t(), prompt :: String.t() | nil) ::
              {command :: [String.t()], claude_session_id :: String.t() | nil}
  @callback detect_running?() :: boolean()
  @callback parse_tier() :: :hooks | :stream | :llm
end
