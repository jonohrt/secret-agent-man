defmodule Sam.Agents.Generic do
  @behaviour Sam.Agents.Behaviour

  @impl true
  def spawn_command(_workdir, _prompt), do: {["/bin/bash", "-l"], nil}

  @impl true
  def detect_running?, do: false

  @impl true
  def parse_tier, do: :llm
end
