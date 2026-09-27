defmodule ServiceRadar.Events.InternalLogPublisherTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Events.InternalLogPublisher

  test "publishes internal logs to JetStream before the live NATS copy" do
    assert :ok =
             InternalLogPublisher.publish(
               "audit",
               %{severity_text: "INFO", body: "created"},
               durable_publish: durable_publish(self()),
               publisher: {__MODULE__, :publish, [self()]}
             )

    assert_receive {:persisted_logs, "logs.internal.audit", json, [msg_id: msg_id]}
    assert {:ok, _} = Ecto.UUID.cast(msg_id)

    assert {:ok, decoded} = Jason.decode(json)
    assert decoded["body"] == "created"
    assert decoded["service_name"] == "serviceradar.core"
    assert is_binary(decoded["timestamp"])

    assert_receive {:published_log, "live.logs.internal.audit", ^json}
  end

  test "skips the live NATS copy when internal_log_live_nats is disabled" do
    previous = Application.get_env(:serviceradar_core, :internal_log_live_nats)

    Application.put_env(:serviceradar_core, :internal_log_live_nats, false)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:serviceradar_core, :internal_log_live_nats)
      else
        Application.put_env(:serviceradar_core, :internal_log_live_nats, previous)
      end
    end)

    assert :ok =
             InternalLogPublisher.publish(
               "health",
               %{severity_text: "INFO", body: "heartbeat"},
               durable_publish: durable_publish(self()),
               publisher: {__MODULE__, :publish, [self()]}
             )

    assert_receive {:persisted_logs, "logs.internal.health", _json, _opts}
    refute_receive {:published_log, "live.logs.internal.health", _json}
  end

  test "treats live NATS publish failure as best-effort after persistence" do
    assert :ok =
             InternalLogPublisher.publish(
               "jobs",
               %{severity_text: "ERROR", body: "failed"},
               durable_publish: durable_publish(self()),
               publisher: {__MODULE__, :publish_fail, [self()]}
             )

    assert_receive {:persisted_logs, "logs.internal.jobs", _json, _opts}
    assert_receive {:publish_attempt, "live.logs.internal.jobs", _json}
  end

  test "returns an error when the log can be neither published nor queued" do
    assert {:error, :db_down} =
             InternalLogPublisher.publish(
               "health",
               %{severity_text: "ERROR", body: "db down"},
               durable_publish: durable_publish_fail(self()),
               publisher: {__MODULE__, :publish, [self()]}
             )

    assert_receive {:persist_attempt, "logs.internal.health"}
    refute_receive {:published_log, _subject, _json}
  end

  defp durable_publish(pid) do
    fn subject, json, opts ->
      send(pid, {:persisted_logs, subject, json, opts})
      :ok
    end
  end

  defp durable_publish_fail(pid) do
    fn subject, _json, _opts ->
      send(pid, {:persist_attempt, subject})
      {:error, :db_down}
    end
  end

  def publish(subject, json, pid) do
    send(pid, {:published_log, subject, json})
    :ok
  end

  def publish_fail(subject, json, pid) do
    send(pid, {:publish_attempt, subject, json})
    {:error, :nats_down}
  end
end
