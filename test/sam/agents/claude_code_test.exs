defmodule Sam.Agents.ClaudeCodeTest do
  use ExUnit.Case, async: true

  describe "spawn_command/2" do
    test "includes --session-id flag" do
      {cmd, _uuid} = Sam.Agents.ClaudeCode.spawn_command("/tmp", nil)
      assert "--session-id" in cmd
    end

    test "returns a valid UUID as second element" do
      {_cmd, uuid} = Sam.Agents.ClaudeCode.spawn_command("/tmp", nil)

      assert Regex.match?(
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
               uuid
             )
    end

    test "includes prompt when provided" do
      {cmd, _uuid} = Sam.Agents.ClaudeCode.spawn_command("/tmp", "fix the bug")
      assert List.last(cmd) == "fix the bug"
      assert "--session-id" in cmd
    end

    test "UUID is included in command after --session-id flag" do
      {cmd, uuid} = Sam.Agents.ClaudeCode.spawn_command("/tmp", nil)
      idx = Enum.find_index(cmd, &(&1 == "--session-id"))
      assert Enum.at(cmd, idx + 1) == uuid
    end
  end
end
