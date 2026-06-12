defmodule ServiceRadar.Events.InternalLogPublisherTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Events.InternalLogPublisher

  test "persists internal logs before publishing the live NATS copy off the persisted stream" do
    assert :ok =
             InternalLogPublisher.publish(
               "audit",
               %{severity_text: "INFO", body: "created"},
               log_processor: {__MODULE__, :process_logs, [self()]},
               publisher: {__MODULE__, :publish, [self()]}
             )

    assert_receive {:persisted_logs, [%{data: json, metadata: metadata}]}
    assert metadata.subject == "logs.internal.audit"
    assert is_struct(metadata.received_at, DateTime)

    assert {:ok, decoded} = Jason.decode(json)
    assert decoded["body"] == "created"
    assert decoded["service_name"] == "serviceradar.core"
    assert is_binary(decoded["timestamp"])

    assert_receive {:published_log, "live.logs.internal.audit", ^json}
  end

  test "treats live NATS publish failure as best-effort after persistence" do
    assert :ok =
             InternalLogPublisher.publish(
               "jobs",
               %{severity_text: "ERROR", body: "failed"},
               log_processor: {__MODULE__, :process_logs, [self()]},
               publisher: {__MODULE__, :publish_fail, [self()]}
             )

    assert_receive {:persisted_logs, [%{metadata: %{subject: "logs.internal.jobs"}}]}
    assert_receive {:publish_attempt, "live.logs.internal.jobs", _json}
  end

  test "returns an error when direct persistence fails" do
    assert {:error, :db_down} =
             InternalLogPublisher.publish(
               "health",
               %{severity_text: "ERROR", body: "db down"},
               log_processor: {__MODULE__, :process_logs_fail, [self()]},
               publisher: {__MODULE__, :publish, [self()]}
             )

    assert_receive {:persist_attempt, "logs.internal.health"}
    refute_receive {:published_log, _subject, _json}
  end

  def process_logs([%{metadata: %{subject: subject}} = message] = messages, pid) do
    send(pid, {:persisted_logs, messages})
    assert subject in ["logs.internal.audit", "logs.internal.jobs"]
    assert is_binary(message.data)
    {:ok, 1}
  end

  def process_logs_fail([%{metadata: %{subject: subject}}], pid) do
    send(pid, {:persist_attempt, subject})
    {:error, :db_down}
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
