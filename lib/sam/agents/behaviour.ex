defmodule Sam.Agents.Behaviour do
  @callback spawn_command(workdir :: String.t(), prompt :: String.t() | nil) :: [String.t()]
  @callback detect_running?() :: boolean()
  @callback parse_tier() :: :hooks | :stream | :llm
end
