defmodule ServiceRadar.Events.OcsfEventPublisherTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Events.OcsfEventPublisher
  alias ServiceRadar.Monitoring.OcsfEvent

  @attrs %{
    class_uid: 1008,
    category_uid: 1,
    type_uid: 100_801,
    activity_id: 1,
    severity_id: 4,
    message: "relay session failed",
    log_name: "camera.relay.session.failed",
    log_provider: "serviceradar.relay_health_event_router",
    metadata: %{"relay_session_id" => "session-alpha"}
  }

  defp capture_publish do
    parent = self()

    fn subject, body, opts ->
      send(parent, {:published, subject, Jason.decode!(body), opts})
      :ok
    end
  end

  defp never_suppress(_attrs), do: false

  test "publishes the event and returns it with the id it was published under" do
    assert {:ok, %OcsfEvent{} = event} =
             OcsfEventPublisher.publish(@attrs,
               family: :camera,
               publish: capture_publish(),
               suppress?: &never_suppress/1
             )

    assert {:ok, _} = Ecto.UUID.cast(event.id)
    assert %DateTime{} = event.time
    assert_received {:published, "events.internal.camera", body, opts}
    assert opts[:msg_id] == event.id
    assert opts[:on_published] == :northbound_handlers
    assert body["id"] == event.id
    assert body["time"] == DateTime.to_iso8601(event.time)
    assert body["message"] == "relay session failed"
    assert body["metadata"] == %{"relay_session_id" => "session-alpha"}
  end

  # EventWriter fills `log_name` and `raw_data` only when the key is absent;
  # sending every field keeps a null the producer set as null.
  test "sends every field, unset ones as explicit nulls" do
    {:ok, _event} =
      OcsfEventPublisher.publish(Map.delete(@attrs, :log_name),
        family: :camera,
        publish: capture_publish(),
        suppress?: &never_suppress/1
      )

    assert_received {:published, _subject, body, _opts}
    assert Map.has_key?(body, "log_name") and body["log_name"] == nil
    assert Map.has_key?(body, "raw_data") and body["raw_data"] == nil
    assert body["observables"] == []
    assert body["device"] == %{}
  end

  test "keeps an id and time the producer assigned" do
    id = Ecto.UUID.generate()
    time = ~U[2026-01-15 10:00:00.123456Z]

    {:ok, event} =
      OcsfEventPublisher.publish(Map.merge(@attrs, %{id: id, time: time}),
        family: :alert,
        publish: capture_publish(),
        suppress?: &never_suppress/1
      )

    assert event.id == id
    assert event.time == time
    assert_received {:published, "events.internal.alert", %{"id" => ^id}, _opts}
  end

  test "an out-of-service device produces no event" do
    assert {:error, :suppressed} =
             OcsfEventPublisher.publish(@attrs,
               family: :camera,
               publish: capture_publish(),
               suppress?: fn _attrs -> true end
             )

    refute_received {:published, _, _, _}
  end

  test "a synthetic liveness probe is returned but never published" do
    attrs =
      put_in(@attrs, [:metadata], %{"serviceradar" => %{"synthetic_liveness_check" => true}})

    assert {:ok, %OcsfEvent{}} =
             OcsfEventPublisher.publish(attrs,
               family: :alert,
               publish: capture_publish(),
               suppress?: &never_suppress/1
             )

    refute_received {:published, _, _, _}
  end

  test "an event queued for retry is still returned to the caller" do
    assert {:ok, %OcsfEvent{}} =
             OcsfEventPublisher.publish(@attrs,
               family: :jobs,
               publish: fn _subject, _body, _opts -> {:ok, :enqueued} end,
               suppress?: &never_suppress/1
             )
  end

  test "an event that could be neither published nor queued is an error" do
    assert {:error, :down} =
             OcsfEventPublisher.publish(@attrs,
               family: :jobs,
               publish: fn _subject, _body, _opts -> {:error, :down} end,
               suppress?: &never_suppress/1
             )
  end

  test "a family outside the closed list is refused" do
    assert_raise KeyError, fn ->
      OcsfEventPublisher.publish(@attrs, family: :operator_supplied, publish: capture_publish())
    end
  end
end
