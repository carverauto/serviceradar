defmodule ServiceRadar.Observability.StatefulAlertEngine.AlertLifecycleEventTest do
  @moduledoc """
  The event a stateful rule emits when it fires is what an operator opens from the
  event stream, and the alert copies its description from it. It used to be a
  rollup of the rule's group: a fixed message, no device, no observables, and the
  status Failure on every one, so it could not say where a problem was or what it
  was without opening the alert.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.StatefulAlertEngine.AlertLifecycle

  @device_uid "sr:00000000-0000-4000-8000-000000000001"
  @now ~U[2026-01-05 05:47:01Z]
  @source_message "Seasonal anomaly: cpu usage_percent breached its hour-of-week baseline (residual z=7.98)"

  describe "build_event/5" do
    test "a fixed message carries the triggering event's message" do
      event = AlertLifecycle.build_event(rule("Anomaly finding"), snapshot(), record(), @now, %{})

      assert event.message == "Anomaly finding: " <> @source_message
    end

    test "a template that names its subject is rendered as written" do
      event =
        AlertLifecycle.build_event(rule("Anomaly on {device}"), snapshot(), record(), @now, %{})

      assert event.message == "Anomaly on #{@device_uid}"
    end

    test "without a template, the triggering event's message is the message" do
      event = AlertLifecycle.build_event(rule(nil), snapshot(), record(), @now, %{})

      assert event.message == @source_message
    end

    test "it carries the device it is given and the triggering event's observables" do
      device = %{"uid" => @device_uid, "hostname" => "host01.example.com"}

      event =
        AlertLifecycle.build_event(rule("Anomaly finding"), snapshot(), record(), @now, device)

      assert event.device == device
      assert event.observables == record().observables
    end

    test "it is not stamped Failure, and the triggering event's status is the detail" do
      event = AlertLifecycle.build_event(rule("Anomaly finding"), snapshot(), record(), @now, %{})

      assert is_nil(Map.get(event, :status_id))
      assert is_nil(Map.get(event, :status))
      assert event.status_detail == "breach"
    end
  end

  test "bulk-insert event UUIDs remain usable JSON source references" do
    uuid = "00000000-0000-4000-8000-0000000000cc"
    source = record(%{id: Ecto.UUID.dump!(uuid)})
    event = AlertLifecycle.build_event(rule("Anomaly finding"), snapshot(), source, @now, %{})

    assert event.unmapped["source_event_id"] == uuid
    assert {:ok, encoded} = Jason.encode(event.unmapped)
    assert Jason.decode!(encoded)["source_event_id"] == uuid
  end

  describe "event_device/3" do
    test "takes the resolved device with the triggering event's hostname and ip" do
      assert AlertLifecycle.event_device(record(), @device_uid, true) == %{
               "uid" => @device_uid,
               "hostname" => "host01.example.com",
               "ip" => "192.0.2.10"
             }
    end

    test "a resolved device the triggering event did not describe carries only its uid" do
      assert AlertLifecycle.event_device(record(%{device: %{}}), @device_uid, true) == %{
               "uid" => @device_uid
             }
    end

    # OcsfEvent :record rejects operational events for an out-of-service device.
    # Incidents for such a device fired before the event carried a device, so the
    # event is recorded without one rather than losing the incident.
    test "an out-of-service device is left off so the incident still records" do
      assert AlertLifecycle.event_device(record(), @device_uid, false) == %{}
    end

    test "no resolved device means no device" do
      assert AlertLifecycle.event_device(record(), nil, true) == %{}
    end
  end

  defp rule(message) do
    event =
      if is_binary(message),
        do: %{"log_name" => "alert.health.causal_prediction", "message" => message},
        else: %{"log_name" => "alert.health.causal_prediction"}

    %{
      id: "00000000-0000-4000-8000-0000000000aa",
      name: "causal_prediction_health_finding",
      threshold: 1,
      window_seconds: 300,
      bucket_seconds: 60,
      cooldown_seconds: 300,
      renotify_seconds: 21_600,
      event: event,
      alert: %{"title" => "Anomaly Finding", "severity_from" => "source"}
    }
  end

  defp snapshot do
    %{
      group_key: "device=#{@device_uid}",
      group_values: %{"device" => @device_uid},
      window_count: 1,
      diagnostics: nil,
      first_seen_at: nil,
      last_seen_at: nil
    }
  end

  defp record(overrides \\ %{}) do
    Map.merge(
      %{
        id: "00000000-0000-4000-8000-0000000000bb",
        time: ~U[2026-01-05 05:47:00Z],
        log_name: "signals.analytics.predictions.example",
        log_provider: "seasonal_disposition",
        message: @source_message,
        status: "breach",
        severity: "Medium",
        severity_id: 3,
        device: %{"uid" => @device_uid, "hostname" => "host01.example.com", "ip" => "192.0.2.10"},
        observables: [%{"name" => "device.uid", "type_id" => 10, "value" => @device_uid}],
        unmapped: %{"anomaly" => %{"metric_name" => "usage_percent", "state" => "anomaly_open"}},
        metadata: %{}
      },
      overrides
    )
  end
end
