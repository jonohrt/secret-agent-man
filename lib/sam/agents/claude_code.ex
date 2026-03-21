defmodule Sam.Agents.ClaudeCode do
  @behaviour Sam.Agents.Behaviour
  import Bitwise

  @impl true
  def spawn_command(_workdir, prompt) do
    uuid = generate_uuid()
    base = ["claude", "--session-id", uuid, "--dangerously-skip-permissions"]
    cmd = if prompt && prompt != "", do: base ++ [prompt], else: base
    {cmd, uuid}
  end

  @impl true
  def detect_running? do
    case System.cmd("pgrep", ["-f", "claude"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  @impl true
  def parse_tier, do: :jsonl

  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = (c &&& 0x0FFF) ||| 0x4000
    d = (d &&& 0x3FFF) ||| 0x8000

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end
end
