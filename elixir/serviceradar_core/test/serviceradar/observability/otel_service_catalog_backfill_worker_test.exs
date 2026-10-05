defmodule ServiceRadar.Observability.OtelServiceCatalogBackfillWorkerTest do
  @moduledoc """
  Seeds the OTel service catalog from the real CNPG rollups.

  The rollups are continuous aggregates, and refreshing one cannot run inside a
  transaction, so this test is unboxed: it writes uniquely named raw rows,
  refreshes the three aggregates, and removes its rows again on exit.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Observability.OtelServiceCatalogBackfillWorker
  alias ServiceRadar.Repo

  @moduletag :integration
  @moduletag sandbox: :unboxed

  @caggs [
    "platform.logs_severity_stats_5m",
    "platform.spans_red_1h",
    "platform.otel_metrics_hourly_stats"
  ]

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  test "seeds each signal from its rollup, only moves timestamps forward, and is re-runnable" do
    suffix = System.unique_integer([:positive])
    logs_only = "svc-logs-#{suffix}"
    traced = "svc-traced-#{suffix}"
    metered = "svc-metered-#{suffix}"
    names = [logs_only, traced, metered]

    now = DateTime.truncate(DateTime.utc_now(), :second)
    seen = DateTime.shift(now, hour: -26)
    window = {DateTime.shift(now, day: -3), DateTime.shift(now, hour: 1)}

    on_exit(fn ->
      Repo.query!("DELETE FROM platform.logs WHERE service_name = ANY($1)", [names])
      Repo.query!("DELETE FROM platform.otel_traces WHERE service_name = ANY($1)", [names])
      Repo.query!("DELETE FROM platform.otel_metrics WHERE service_name = ANY($1)", [names])
      refresh!(window)

      Repo.query!("DELETE FROM platform.otel_service_catalog WHERE service_name = ANY($1)", [
        names
      ])
    end)

    Repo.query!(
      """
      INSERT INTO platform.logs ("timestamp", severity_text, body, service_name)
      VALUES ($1, 'INFO', 'backfill probe', $2), ($1, 'INFO', 'backfill probe', $3)
      """,
      [seen, logs_only, traced]
    )

    Repo.query!(
      """
      INSERT INTO platform.otel_traces
        ("timestamp", trace_id, span_id, name, service_name,
         start_time_unix_nano, end_time_unix_nano, status_code)
      VALUES ($1, '4bf92f3577b34da6a3ce929d0e0e4736', '00f067aa0ba902b7', 'GET /cart', $2,
              0, 1000000, 1)
      """,
      [seen, traced]
    )

    Repo.query!(
      """
      INSERT INTO platform.otel_metrics ("timestamp", span_id, service_name, span_name, duration_ms)
      VALUES ($1, '53995c3f42cd8ad8', $2, 'charge', 12.5)
      """,
      [seen, metered]
    )

    # EventWriter already saw traces for this service more recently than any rollup bucket.
    Repo.query!(
      """
      INSERT INTO platform.otel_service_catalog (service_name, traces_last_seen_at, last_seen_at)
      VALUES ($1, $2, $2)
      """,
      [traced, now]
    )

    refresh!(window)

    assert :ok = OtelServiceCatalogBackfillWorker.perform(%Oban.Job{args: %{}})
    first = rows(names)

    assert %{logs: %DateTime{}, traces: nil, metrics: nil} = first[logs_only]
    assert %{logs: nil, traces: nil, metrics: %DateTime{}} = first[metered]

    assert %{logs: %DateTime{} = logs_at, traces: traces_at, last: last_at} = first[traced]
    assert DateTime.before?(logs_at, now)
    assert DateTime.compare(traces_at, now) == :eq
    assert DateTime.compare(last_at, now) == :eq

    assert :ok = OtelServiceCatalogBackfillWorker.perform(%Oban.Job{args: %{}})
    assert rows(names) == first
  end

  defp refresh!({start, stop}) do
    for cagg <- @caggs do
      Repo.query!(
        "CALL refresh_continuous_aggregate('#{cagg}', $1::timestamptz, $2::timestamptz)",
        [start, stop]
      )
    end
  end

  defp rows(names) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT service_name, logs_last_seen_at, traces_last_seen_at, metrics_last_seen_at,
               last_seen_at
        FROM platform.otel_service_catalog
        WHERE service_name = ANY($1)
        """,
        [names]
      )

    Map.new(rows, fn [name, logs, traces, metrics, last] ->
      {name, %{logs: logs, traces: traces, metrics: metrics, last: last}}
    end)
  end
end
