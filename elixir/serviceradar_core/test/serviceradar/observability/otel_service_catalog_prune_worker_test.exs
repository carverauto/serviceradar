defmodule ServiceRadar.Observability.OtelServiceCatalogPruneWorkerTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Observability.OtelServiceCatalogPruneWorker
  alias ServiceRadar.Repo

  defp days_ago(days), do: DateTime.shift(DateTime.utc_now(), day: -days)

  defp insert!(name, logs, traces, metrics) do
    last = [logs, traces, metrics] |> Enum.reject(&is_nil/1) |> Enum.max(DateTime)

    Repo.query!(
      """
      INSERT INTO platform.otel_service_catalog
        (service_name, logs_last_seen_at, traces_last_seen_at, metrics_last_seen_at, last_seen_at)
      VALUES ($1, $2, $3, $4, $5)
      """,
      [name, logs, traces, metrics, last]
    )
  end

  defp row(name) do
    case Repo.query!(
           """
           SELECT logs_last_seen_at, traces_last_seen_at, metrics_last_seen_at, last_seen_at
           FROM platform.otel_service_catalog WHERE service_name = $1
           """,
           [name]
         ) do
      %{rows: [[logs, traces, metrics, last]]} ->
        %{logs: logs, traces: traces, metrics: metrics, last: last}

      %{rows: []} ->
        nil
    end
  end

  test "deletes stale services and clears stale signals of the ones kept" do
    suffix = System.unique_integer([:positive])
    stale = "svc-stale-#{suffix}"
    mixed = "svc-mixed-#{suffix}"
    fresh = "svc-fresh-#{suffix}"

    recent = days_ago(2)
    insert!(stale, days_ago(45), days_ago(40), nil)
    insert!(mixed, recent, days_ago(40), days_ago(35))
    insert!(fresh, nil, recent, nil)

    assert :ok = OtelServiceCatalogPruneWorker.perform(%Oban.Job{args: %{}})

    assert row(stale) == nil

    assert %{logs: logs, traces: nil, metrics: nil, last: last} = row(mixed)
    assert DateTime.compare(logs, recent) == :eq
    assert DateTime.compare(last, recent) == :eq

    assert %{logs: nil, traces: traces, metrics: nil} = row(fresh)
    assert DateTime.compare(traces, recent) == :eq
  end
end
