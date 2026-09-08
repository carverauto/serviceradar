defmodule ServiceRadar.Observability.SeasonalDisposition.EdgeBaselineProducerDbTest do
  @moduledoc """
  Real SRQL/CNPG regression coverage for edge seasonal baseline delivery.

  This uses the production continuous aggregate and the SRQL NIF translation;
  a fake runner cannot detect a regression that reduces the profile back to
  one latest bucket per series.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Observability.SeasonalDisposition.EdgeBaselineProducer
  alias ServiceRadar.Observability.SeasonalDisposition.Source
  alias ServiceRadar.Repo

  @moduletag :integration
  @moduletag sandbox: :unboxed

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  test "delivers the real full hour-of-week profile through SRQL" do
    unique = System.unique_integer([:positive])
    device_id = "sr:edge-baseline-db-#{unique}"
    gateway_id = "edge-baseline-db-gateway-#{unique}"
    series_key = "sysmon:cpu:#{device_id}"
    now = DateTime.truncate(DateTime.utc_now(), :second)
    start = DateTime.add(now, -6 * 7 * 24 * 60 * 60, :second)

    on_exit(fn ->
      Repo.query!("DELETE FROM platform.timeseries_metrics WHERE series_key = $1", [series_key])
      refresh_hourly!(start, DateTime.add(now, 24 * 60 * 60, :second))
    end)

    Repo.query!(
      """
      INSERT INTO platform.timeseries_metrics (
        "timestamp", gateway_id, agent_id, series_key, device_id,
        metric_type, metric_name, value
      )
      SELECT
        $1::timestamptz + make_interval(hours => slot::integer),
        $2,
        'edge-baseline-db-agent',
        $3,
        $4,
        'sysmon.cpu',
        'cpu.usage_percent',
        20.0 + (slot % 24)
      FROM generate_series(0, 6 * 7 * 24 - 1) AS slot
      """,
      [start, gateway_id, series_key, device_id]
    )

    refresh_hourly!(start, DateTime.add(now, 24 * 60 * 60, :second))

    source =
      Enum.find(Source.defaults(), &(&1.name == "cpu_seasonal"))

    assert {:ok, baselines} = EdgeBaselineProducer.build(sources: [source])

    assert %{"buckets" => buckets} =
             Map.fetch!(baselines, "#{device_id}|cpu.usage_percent")

    assert length(buckets) == 168
    assert Enum.any?(buckets, &(&1["dow"] == 0 and &1["hod"] == 0))
    assert Enum.any?(buckets, &(&1["dow"] == 6 and &1["hod"] == 23))
  end

  defp refresh_hourly!(start, stop) do
    Repo.query!(
      "CALL refresh_continuous_aggregate('platform.timeseries_metrics_hourly', $1::timestamptz, $2::timestamptz)",
      [start, stop]
    )
  end
end
