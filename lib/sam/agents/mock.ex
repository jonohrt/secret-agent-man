defmodule Sam.Agents.Mock do
  @behaviour Sam.Agents.Behaviour

  @impl true
  def spawn_command(_workdir, _prompt) do
    {[Path.join(:code.priv_dir(:sam), "test/mock_agent.sh")], nil}
  end

  @impl true
  def detect_running?, do: false

  @impl true
  def parse_tier, do: :hooks
end
