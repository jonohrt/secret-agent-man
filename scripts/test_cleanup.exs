home = System.user_home!()
path = Path.join(home, ".config/secret-agent-man/data/sam_sessions") |> to_charlist()
{:ok, table} = :dets.open_file(:sam_debug2, file: path, type: :set)

# Insert some fake data
:dets.insert(table, {"fake-session-1", %{session_id: "fake-session-1", name: "Fake"}})

# Verify insert
IO.inspect(:dets.lookup(table, "fake-session-1"), label: "Before cleanup")

# Test cleanup_stale
:dets.delete_all_objects(table)

IO.inspect(:dets.lookup(table, "fake-session-1"), label: "After cleanup")
:dets.close(table)
