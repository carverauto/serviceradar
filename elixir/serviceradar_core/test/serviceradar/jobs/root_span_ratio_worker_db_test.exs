defmodule ServiceRadar.Jobs.RootSpanRatioWorkerDbTest do
  use ServiceRadar.DataCase, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.Jobs.RootSpanRatioWorker
  alias ServiceRadar.Repo

  # Connection-local stand-in shadows the unqualified `otel_traces` table read
  # by `RootSpanRatioWorker.counts_sql/0`, so the shared hypertable is untouched
  # and the sandbox transaction pins NOW().
  setup do
    Repo.query!("""
    CREATE TEMP TABLE otel_traces (
      timestamp timestamptz NOT NULL,
      trace_id text,
      span_id text NOT NULL,
      service_name text,
      parent_span_id text,
      kind int,
      links text
    ) ON COMMIT DROP
    """)

    :ok
  end

  test "counts_sql excludes linked consumer root spans while retaining children, unlinked consumer roots, and non-consumer roots" do
    rows = [
      # Linked consumer root (kind = 5, non-empty links) -> excluded
      %{
        offset_minutes: -2,
        trace_id: "10000000000000000000000000000001",
        span_id: "1000000000000001",
        parent_span_id: nil,
        kind: 5,
        links: ~s([{"trace_id":"20000000000000000000000000000001","span_id":"2000000000000001"}])
      },
      # Unlinked consumer roots (NULL, '', '[]') -> counted as roots
      %{
        offset_minutes: -2,
        trace_id: "10000000000000000000000000000002",
        span_id: "1000000000000002",
        parent_span_id: nil,
        kind: 5,
        links: nil
      },
      %{
        offset_minutes: -2,
        trace_id: "10000000000000000000000000000003",
        span_id: "1000000000000003",
        parent_span_id: nil,
        kind: 5,
        links: "[]"
      },
      # Server root with links (kind = 2) -> counted as root
      %{
        offset_minutes: -2,
        trace_id: "10000000000000000000000000000004",
        span_id: "1000000000000004",
        parent_span_id: nil,
        kind: 2,
        links: ~s([{"trace_id":"20000000000000000000000000000001","span_id":"2000000000000001"}])
      },
      # Child consumer span with links -> counted in total_spans, not root_spans
      %{
        offset_minutes: -2,
        trace_id: "10000000000000000000000000000004",
        span_id: "1000000000000005",
        parent_span_id: "1000000000000004",
        kind: 5,
        links: ~s([{"trace_id":"20000000000000000000000000000001","span_id":"2000000000000001"}])
      },
      # Internal child span -> counted in total_spans, not root_spans
      %{
        offset_minutes: -2,
        trace_id: "10000000000000000000000000000004",
        span_id: "1000000000000006",
        parent_span_id: "1000000000000004",
        kind: 1,
        links: "[]"
      },
      # Out-of-window unlinked root -> excluded by window filter
      %{
        offset_minutes: -20,
        trace_id: "10000000000000000000000000000007",
        span_id: "1000000000000007",
        parent_span_id: nil,
        kind: 2,
        links: "[]"
      }
    ]

    for row <- rows do
      Repo.query!(
        """
        INSERT INTO otel_traces (timestamp, trace_id, span_id, parent_span_id, kind, links)
        VALUES (NOW() + ($1::int * INTERVAL '1 minute'), $2, $3, $4, $5, $6)
        """,
        [row.offset_minutes, row.trace_id, row.span_id, row.parent_span_id, row.kind, row.links]
      )
    end

    in_window = Enum.filter(rows, &(&1.offset_minutes > -RootSpanRatioWorker.window_minutes()))
    expected = RootSpanRatioWorker.count_spans(in_window)

    %{rows: [[total_spans, root_spans]]} =
      Repo.query!(RootSpanRatioWorker.counts_sql(), [RootSpanRatioWorker.window_minutes()])

    assert {total_spans, root_spans} == {5, 3}
    assert {total_spans, root_spans} == expected
  end

  test "a breach names its top contributors among the roots it counts, and no cause" do
    # Synthetic producers: 700 unlinked consumer roots, 300 client roots, and 400 linked
    # consumer roots the signal excludes, so they must not be reported either.
    insert_roots("svc-alpha", 5, nil, 700)
    insert_roots("svc-bravo", 3, nil, 300)
    insert_roots("svc-charlie", 5, ~s([{"trace_id":"20000000000000000000000000000001"}]), 400)

    log = capture_log(fn -> assert :ok = RootSpanRatioWorker.perform(%Oban.Job{}) end)

    assert log =~ "Root span ratio breach"
    assert log =~ "top contributors: svc-alpha/consumer=700, svc-bravo/client=300"
    refute log =~ "svc-charlie"
    refute log =~ "lost at ingest"
  end

  defp insert_roots(service, kind, links, count) do
    Repo.query!(
      """
      INSERT INTO otel_traces (timestamp, trace_id, span_id, service_name, parent_span_id, kind, links)
      SELECT NOW() - INTERVAL '1 minute', lpad(to_hex(n), 32, '0'), lpad(to_hex(n), 16, '0'), $1, NULL, $2, $3
      FROM generate_series(1, $4::int) AS n
      """,
      [service, kind, links, count]
    )
  end
end
