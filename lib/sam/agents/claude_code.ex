defmodule Sam.Agents.ClaudeCode do
  @behaviour Sam.Agents.Behaviour

  @impl true
  def spawn_command(_workdir, prompt) do
    base = ["claude", "--dangerously-skip-permissions"]
    if prompt && prompt != "", do: base ++ [prompt], else: base
  end

  @impl true
  def detect_running? do
    case System.cmd("pgrep", ["-f", "claude"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  @impl true
  def parse_tier, do: :hooks
end
