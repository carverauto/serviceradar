defmodule ServiceRadarWebNGWeb.Settings.AuditEventsAccessTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias ServiceRadarWebNGWeb.Settings.AuditLive.Events

  @moduletag :db_free

  test "an unauthorized socket ignores both broadcasts and every audit event action" do
    socket = %Socket{assigns: %{__changed__: %{}, current_scope: nil}}
    assert {:ok, socket} = Events.mount(%{}, %{}, socket)
    refute socket.assigns.can_view?

    assert {:noreply, ^socket} =
             Events.handle_info({:security_event, %{id: "invented-event"}}, socket)

    for event <- [
          "filter",
          "clear-filters",
          "next-page",
          "previous-page",
          "show-event",
          "close-event"
        ] do
      assert {:noreply, ^socket} = Events.handle_event(event, %{}, socket)
    end
  end

  test "an authorized disconnected mount never loads security event rows" do
    scope = %{user: %{role: :operator, permissions: MapSet.new(["settings.audit.view"])}}
    socket = %Socket{assigns: %{__changed__: %{}, current_scope: scope}}
    assert {:ok, socket} = Events.mount(%{}, %{}, socket)
    assert socket.assigns.can_view?
    assert socket.assigns.events == []
    refute socket.assigns.has_next?
    assert socket.assigns.query_error == nil
  end
end
