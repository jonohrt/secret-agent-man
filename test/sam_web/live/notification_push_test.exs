defmodule SamWeb.NotificationPushTest do
  use SamWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "pushes notify event on transition to needs_input", %{conn: conn} do
    session_id = "test-notif-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      GenServer.start_link(Sam.Session.Server, %{
        session_id: session_id,
        name: "Notif Test"
      })

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, view, _html} = live(conn, "/")

    # Transition to needs_input (server handles :input_needed type)
    send(pid, {:parser_event, session_id, %{type: :input_needed, timestamp: DateTime.utc_now()}})

    # The push_event should be sent to the client
    assert_push_event(view, "notify", %{
      status: "needs_input",
      session_name: "Notif Test"
    })
  end

  test "does not push notify event on working transition", %{conn: conn} do
    session_id = "test-notif-no-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      GenServer.start_link(Sam.Session.Server, %{
        session_id: session_id,
        name: "No Notif Test"
      })

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, view, _html} = live(conn, "/")

    # Transition to working
    send(
      pid,
      {:parser_event, session_id,
       %{type: :tool_call, tool: "Read", timestamp: DateTime.utc_now()}}
    )

    # Should NOT push a notify event for working
    refute_push_event(view, "notify", %{status: "working"}, 500)
  end
end
