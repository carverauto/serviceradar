defmodule ServiceRadar.EventWriter.Processors.AnalyticsSignalsProcessBatchDBTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.EventWriter.Processors.AnalyticsSignals
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  defmodule AlertQueue do
    @moduledoc false

    def enqueue_events(events) do
      send(self(), {:alert_evaluation_events, events})
      :ok
    end
  end

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    previous_queue = Application.get_env(:serviceradar_core, :stateful_alert_evaluation_queue)

    Application.put_env(
      :serviceradar_core,
      :stateful_alert_evaluation_queue,
      __MODULE__.AlertQueue
    )

    on_exit(fn ->
      restore_env(:stateful_alert_evaluation_queue, previous_queue)
    end)
  end

  test "bulk recorded causal predictions skip duplicate delivery without alert re-enqueue" do
    message = anomaly_message()
    row = AnalyticsSignals.parse_message(message)

    delete_event!(row)
    on_exit(fn -> delete_event!(row) end)

    assert {:ok, 1} = AnalyticsSignals.process_batch([message])
    assert event_count(row) == 1

    assert_receive {:alert_evaluation_events, [alert_row]}
    assert alert_row.id == uuid_string(row.id)
    assert alert_row.metadata["event_identity"] == row.metadata["event_identity"]

    assert {:ok, 1} = AnalyticsSignals.process_batch([message])
    assert event_count(row) == 1
    refute_receive {:alert_evaluation_events, _}, 100
  end

  defp anomaly_message do
    subject = "signals.causal.predictions.test-series-bulk-record"

    payload = %{
      "event_id" => "bulk-recorded-anomaly-#{System.unique_integer([:positive])}",
      "signal_type" => "causal",
      "event_type" => "anomaly",
      "class_uid" => 2004,
      "time" => 1_812_456_000_000,
      "severity_id" => 4,
      "device_uid" => "sr:bulk-record-device",
      "anomaly" => %{
        "series_key" => "test-series-bulk-record",
        "metric_class" => "sysmon.cpu",
        "state" => "anomaly_open",
        "score" => 4.2
      }
    }

    %{
      data: Jason.encode!(payload),
      metadata: %{subject: subject, received_at: DateTime.utc_now()}
    }
  end

  defp delete_event!(nil), do: :ok

  defp delete_event!(row) do
    Repo.query!(
      "DELETE FROM platform.ocsf_events WHERE id = ($1::text)::uuid AND time = $2",
      [uuid_string(row.id), row.time]
    )

    :ok
  end

  defp event_count(row) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.ocsf_events WHERE id = ($1::text)::uuid AND time = $2",
        [uuid_string(row.id), row.time]
      )

    count
  end

  defp uuid_string(<<_::128>> = id) do
    {:ok, uuid} = Ecto.UUID.load(id)
    uuid
  end

  defp uuid_string(id) when is_binary(id) do
    {:ok, uuid} = Ecto.UUID.cast(id)
    uuid
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
