defmodule Sam.PersistenceTest do
  use ExUnit.Case, async: false

  setup do
    tmp_dir = System.tmp_dir!()
    dets_path = Path.join(tmp_dir, "test_persistence_#{System.unique_integer([:positive])}")
    {:ok, table} = :dets.open_file(:test_persistence, file: to_charlist(dets_path), type: :set)
    :dets.delete_all_objects(table)

    on_exit(fn ->
      :dets.close(table)
      File.rm(dets_path)
    end)

    %{table: table}
  end

  test "load_saved_sessions returns all entries", %{table: table} do
    :dets.insert(table, {"session-1", %{session_id: "session-1", name: "Test 1", workdir: "/tmp", agent_type: :claude_code, status: :idle}})
    :dets.insert(table, {"session-2", %{session_id: "session-2", name: "Test 2", workdir: "/home", agent_type: :claude_code, status: :working}})

    sessions = Sam.Persistence.load_saved_sessions(table)
    assert length(sessions) == 2
    assert Enum.any?(sessions, &(&1.name == "Test 1"))
  end

  test "delete_session removes entry", %{table: table} do
    :dets.insert(table, {"session-1", %{session_id: "session-1", name: "Del Test"}})
    Sam.Persistence.delete_session(table, "session-1")

    assert :dets.lookup(table, "session-1") == []
  end
end
