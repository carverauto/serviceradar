defmodule ServiceRadar.ResultIngestion.LaneMetricsPersistenceDbTest do
  @moduledoc """
  What LaneMetrics publishes on `metrics.ingestion_lanes` is accepted by the
  EventWriter Metrics processor and lands in timeseries_metrics.
  """
  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.EventWriter.Processors.Metrics
  alias ServiceRadar.Repo
  alias ServiceRadar.ResultIngestion.LaneMetrics
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "a published lane metric batch is persisted as timeseries metrics" do
    # A timestamp no other test writes, so the rows read back are this batch's.
    now =
      DateTime.shift(~U[2026-01-01 00:00:00.000000Z], second: System.unique_integer([:positive]))

    test_pid = self()

    publish = fn subject, body ->
      send(test_pid, {:published, subject, body})
      :ok
    end

    if Process.whereis(LaneMetrics), do: stop_supervised(LaneMetrics)

    start_supervised!(
      {LaneMetrics, publish: publish, now: fn -> now end, interval_ms: to_timeout(hour: 1)}
    )

    :telemetry.execute(
      [:serviceradar, :result_ingestion, :state],
      %{pending_count: 7, pending_bytes: 70, in_flight_count: 2, in_flight_bytes: 20},
      %{class: :sweep}
    )

    :telemetry.execute([:serviceradar, :result_ingestion, :rejected], %{count: 1}, %{
      class: :sweep,
      reason: :result_ingestion_queue_full
    })

    :ok = LaneMetrics.publish_now()
    assert_received {:published, "metrics.ingestion_lanes", body}

    assert {:ok, written} =
             Metrics.process_batch([
               %{data: body, metadata: %{subject: "metrics.ingestion_lanes"}}
             ])

    assert written > 0

    rows =
      Repo.all(
        from(m in "timeseries_metrics",
          prefix: "platform",
          where: m.timestamp == ^now and fragment("?->>'lane' = 'sweep'", m.tags),
          select: {m.metric_name, m.value, m.tags}
        )
      )

    by_name = Map.new(rows, fn {name, value, tags} -> {name, {value, tags}} end)

    assert {7.0, _tags} = by_name["ingestion_lane_depth"]
    assert {2.0, _tags} = by_name["ingestion_lane_in_flight"]

    assert {1.0, %{"reason" => "result_ingestion_queue_full"}} =
             by_name["ingestion_lane_rejected"]
  end
end
