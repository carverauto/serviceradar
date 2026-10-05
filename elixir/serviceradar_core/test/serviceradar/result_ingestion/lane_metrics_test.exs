defmodule ServiceRadar.ResultIngestion.LaneMetricsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Observability.MetricEnvelope
  alias ServiceRadar.ResultIngestion.KeyedQueue
  alias ServiceRadar.ResultIngestion.LaneMetrics

  @moduletag :db_free

  @now ~U[2026-10-05 12:00:00.000000Z]

  setup do
    test_pid = self()

    publish = fn subject, body ->
      send(test_pid, {:published, subject, body})
      Application.get_env(:serviceradar_core, :lane_metrics_test_publish_result, :ok)
    end

    previous = Application.fetch_env(:serviceradar_core, :lane_metrics_test_publish_result)

    on_exit(fn ->
      case previous do
        {:ok, value} ->
          Application.put_env(:serviceradar_core, :lane_metrics_test_publish_result, value)

        :error ->
          Application.delete_env(:serviceradar_core, :lane_metrics_test_publish_result)
      end
    end)

    start_supervised!(
      {LaneMetrics, publish: publish, now: fn -> @now end, interval_ms: to_timeout(hour: 1)}
    )

    supervisor = start_supervised!(Task.Supervisor)
    %{supervisor: supervisor}
  end

  test "a queue's depth and rejections are published as one metric batch the Metrics processor decodes",
       ctx do
    queue = start_queue!(ctx)
    test_pid = self()

    :ok =
      KeyedQueue.admit(queue, :agent_a, 0, fn ->
        receive(do: (:release -> send(test_pid, :done)))
      end)

    :ok = KeyedQueue.admit(queue, :agent_a, 0, fn -> :ok end)
    {:error, :result_ingestion_key_full} = KeyedQueue.admit(queue, :agent_a, 0, fn -> :ok end)

    :ok = LaneMetrics.publish_now()
    assert_received {:published, "metrics.ingestion_lanes", body}
    refute_received {:published, _subject, _body}

    rows = body |> MetricEnvelope.decode_rows() |> ok_rows()

    assert value(rows, "ingestion_lane_depth", "sweep") == 1.0
    assert value(rows, "ingestion_lane_in_flight", "sweep") == 1.0
    assert value(rows, "ingestion_lane_admitted", "sweep") == 2.0
    assert value(rows, "ingestion_lane_capacity", "sweep") == 512.0

    assert [%{value: 1.0} = rejected] = matching(rows, "ingestion_lane_rejected", "sweep")
    assert rejected.tags["reason"] == "result_ingestion_key_full"
    assert Enum.all?(rows, &(&1.timestamp == @now))
    refute Enum.any?(rows, &Map.has_key?(&1.tags, "agent_id"))
  end

  test "interval counts are published once and the snapshot keeps the last interval" do
    :telemetry.execute([:serviceradar, :admission_lane, :rejected], %{count: 1}, %{
      lane: :retained_plugin_result,
      reason: :per_agent_full
    })

    :telemetry.execute([:serviceradar, :admission_lane, :timeout], %{count: 1}, %{
      lane: :retained_plugin_result
    })

    :ok = LaneMetrics.publish_now()
    assert_received {:published, _subject, first}
    first_rows = first |> MetricEnvelope.decode_rows() |> ok_rows()
    assert value(first_rows, "ingestion_lane_nacked", "retained_plugin_result") == 2.0

    :ok = LaneMetrics.publish_now()
    assert_received {:published, _subject, second}

    assert second
           |> MetricEnvelope.decode_rows()
           |> ok_rows()
           |> matching("ingestion_lane_nacked", "retained_plugin_result") == []

    assert {:ok, lanes} = LaneMetrics.snapshot()
    retained = Enum.find(lanes, &(&1.lane == "retained_plugin_result"))
    assert retained.capacity == 32
    assert retained.rejected == 0
  end

  test "a failed publish is logged and leaves collection working" do
    Application.put_env(
      :serviceradar_core,
      :lane_metrics_test_publish_result,
      {:error, :no_stream}
    )

    :telemetry.execute([:serviceradar, :sync_ingestion, :incomplete_run], %{count: 1}, %{})

    log = capture_log(fn -> assert {:error, :no_stream} = LaneMetrics.publish_now() end)
    assert log =~ "Ingestion lane metrics publish failed"

    :telemetry.execute([:serviceradar, :sync_ingestion, :incomplete_run], %{count: 1}, %{})
    assert {:ok, lanes} = LaneMetrics.snapshot()
    assert Enum.find(lanes, &(&1.lane == "sync")).incomplete_runs == 2
  end

  defp start_queue!(ctx) do
    start_supervised!(
      {KeyedQueue,
       name: Module.concat(__MODULE__, "sweep_#{System.unique_integer([:positive])}"),
       class: :sweep,
       task_supervisor: ctx.supervisor,
       workers: 1,
       max_items: 512,
       max_bytes: 1_000_000,
       max_items_per_key: 2,
       job_timeout_ms: 5_000}
    )
  end

  defp ok_rows({:ok, rows}), do: rows
  defp ok_rows(rows) when is_list(rows), do: rows

  defp matching(rows, name, lane),
    do: Enum.filter(rows, &(&1.metric_name == name and &1.tags["lane"] == lane))

  defp value(rows, name, lane) do
    case matching(rows, name, lane) do
      [row] -> row.value
      other -> flunk("expected one #{name} row for #{lane}, got #{inspect(other)}")
    end
  end
end
