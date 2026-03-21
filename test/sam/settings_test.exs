defmodule Sam.SettingsTest do
  use ExUnit.Case, async: false

  setup do
    # Use a temp DETS file to avoid polluting real settings
    tmp_dir = System.tmp_dir!()
    dets_path = Path.join(tmp_dir, "test_settings_#{System.unique_integer([:positive])}")
    {:ok, table} = :dets.open_file(:test_settings, file: to_charlist(dets_path), type: :set)
    :dets.delete_all_objects(table)

    on_exit(fn ->
      :dets.close(table)
      File.rm(dets_path)
    end)

    %{table: table}
  end

  test "get returns default when key not set", %{table: table} do
    assert Sam.Settings.get(table, :default_workdir, "/fallback") == "/fallback"
  end

  test "put and get round-trip", %{table: table} do
    Sam.Settings.put(table, :default_workdir, "/Users/johrt/Code/umbrella")
    assert Sam.Settings.get(table, :default_workdir) == "/Users/johrt/Code/umbrella"
  end

  test "mru_workdirs capped at 5 and deduped", %{table: table} do
    for i <- 1..7 do
      Sam.Settings.add_mru_workdir(table, "/path/#{i}")
    end

    dirs = Sam.Settings.get(table, :mru_workdirs, [])
    assert length(dirs) == 5
    # Most recent first
    assert hd(dirs) == "/path/7"
  end

  test "add_mru_workdir deduplicates existing path", %{table: table} do
    Sam.Settings.add_mru_workdir(table, "/path/a")
    Sam.Settings.add_mru_workdir(table, "/path/b")
    Sam.Settings.add_mru_workdir(table, "/path/a")

    dirs = Sam.Settings.get(table, :mru_workdirs, [])
    assert dirs == ["/path/a", "/path/b"]
  end
end
