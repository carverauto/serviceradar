defmodule ServiceRadar.Events.OcsfEventPublisherDbTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Events.OcsfEventPublisher
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "an operational event for an out-of-service device is suppressed, not published" do
    uid = insert_device!(false)
    parent = self()

    assert {:error, :suppressed} =
             OcsfEventPublisher.publish(event_attrs(uid),
               family: :observability,
               publish: fn _subject, _body, _opts ->
                 send(parent, :published)
                 :ok
               end
             )

    refute_received :published
  end

  # The test environment hands a publish to the EventWriter processor for its
  # subject, so this is the whole path: publisher, JetStream contract, stored row.
  test "an active device's event is published and stored by EventWriter under its id" do
    uid = insert_device!(true)

    assert {:ok, event} = OcsfEventPublisher.publish(event_attrs(uid), family: :observability)

    assert %{rows: [[^uid, "device health changed", "serviceradar.test"]]} =
             Repo.query!(
               """
               SELECT device->>'uid', message, log_provider
               FROM platform.ocsf_events
               WHERE id = $1 AND time = $2
               """,
               [Ecto.UUID.dump!(event.id), event.time]
             )
  end

  defp insert_device!(active?) do
    uid = "sr:publisher-test-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now()

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "publisher-test.example.com",
        is_available: true,
        is_active: active?,
        first_seen_time: now,
        last_seen_time: now
      }
    ])

    uid
  end

  defp event_attrs(device_uid) do
    %{
      class_uid: 1008,
      category_uid: 1,
      type_uid: 100_801,
      activity_id: 1,
      activity_name: "Health Check",
      severity_id: 2,
      severity: "Low",
      message: "device health changed",
      device: %{"uid" => device_uid},
      log_name: "device.health.changed",
      log_provider: "serviceradar.test",
      metadata: %{"source" => "test"}
    }
  end
end
