defmodule ServiceRadar.Observability.ServicesAvailabilityCaggTest do
  # Time-series sparklines (`service_sparklines.ex`) and SRQL
  # `rollup_stats:availability` read `platform.services_availability_5m`.
  # The dashboard Network Health KPI card and `/services` catalog read current
  # distinct service states from `platform.service_state` via
  # `ServiceRadar.Observability.ServiceHealth.summary/1`.
  #
  # The view is real time: a bucket newer than its refresh window is computed
  # from `service_status` at query time, so rows this test inserts inside its own
  # transaction are visible. The bucket holding "one minute ago" always ends
  # after the refresh policy's five-minute end offset, so it is never
  # materialized and never hides them.
  #
  # Within one 5-minute bucket, each service instance counts once per state.
  # Across multiple buckets, the continuous aggregate maintains one row per
  # bucket per instance, which is aggregated over time windows for sparklines.
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Observability.ServiceHealth
  alias ServiceRadar.Repo

  @moduletag :integration

  setup do
    unique = System.unique_integer([:positive])
    minute_ago = DateTime.to_unix(DateTime.utc_now()) - 60
    at = DateTime.from_unix!(div(minute_ago, 300) * 300 + 1)

    report = fn service_name, service_type, agent_id, available, offset_seconds ->
      %{
        timestamp: DateTime.shift(at, second: offset_seconds),
        gateway_id: "gateway-#{unique}",
        agent_id: agent_id,
        service_name: "#{service_name}-#{unique}",
        service_type: service_type,
        available: available
      }
    end

    # A flaps between states, B reports twice while up, C is down.
    rows = [
      report.("svc-a", "http", "agent-1", true, 0),
      report.("svc-a", "http", "agent-1", false, 10),
      report.("svc-b", "http", "agent-1", true, 0),
      report.("svc-b", "http", "agent-1", true, 10),
      report.("svc-c", "grpc", "agent-2", false, 5)
    ]

    {5, _} = Repo.insert_all("service_status", rows, prefix: "platform")

    {:ok,
     names: Enum.map(~w(svc-a svc-b svc-c), &"#{&1}-#{unique}"),
     unique: unique,
     at: at,
     report: report}
  end

  test "each service instance counts once per availability state, by service type", %{
    names: names
  } do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT service_type, SUM(total_count)::bigint, SUM(available_count)::bigint,
               SUM(unavailable_count)::bigint
        FROM platform.services_availability_5m
        WHERE service_name = ANY($1)
        GROUP BY service_type
        ORDER BY service_type
        """,
        [names]
      )

    assert rows == [["grpc", 1, 0, 1], ["http", 2, 2, 1]]
  end

  test "the SRQL availability rollup reads totals and a percentage from it", %{names: names} do
    %{rows: [[payload]]} =
      Repo.query!(
        """
        SELECT jsonb_build_object(
          'total', COALESCE(SUM(total_count), 0)::bigint,
          'available', COALESCE(SUM(available_count), 0)::bigint,
          'unavailable', COALESCE(SUM(unavailable_count), 0)::bigint,
          'availability_pct', CASE
            WHEN COALESCE(SUM(total_count), 0) = 0 THEN 0.0
            ELSE (COALESCE(SUM(available_count), 0)::float
                  / COALESCE(SUM(total_count), 0)::float) * 100.0
          END
        )
        FROM platform.services_availability_5m
        WHERE bucket >= now() - interval '1 hour' AND service_name = ANY($1)
        """,
        [names]
      )

    assert %{"total" => 3, "available" => 2, "unavailable" => 2} = payload
    assert_in_delta payload["availability_pct"], 66.67, 0.01
  end

  test "multi-bucket reports accumulate bucket counts in the CAGG rollup", %{
    names: names,
    report: report
  } do
    # Add reports in an earlier 5-minute bucket (at - 300 seconds) for svc-b
    earlier_rows = [
      report.("svc-b", "http", "agent-1", true, -300),
      report.("svc-b", "http", "agent-1", false, -290)
    ]

    {2, _} = Repo.insert_all("service_status", earlier_rows, prefix: "platform")

    # Summing over the 1-hour window counts svc-b in both buckets, accumulating to 4 total
    %{rows: [[payload]]} =
      Repo.query!(
        """
        SELECT jsonb_build_object(
          'total', COALESCE(SUM(total_count), 0)::bigint,
          'available', COALESCE(SUM(available_count), 0)::bigint,
          'unavailable', COALESCE(SUM(unavailable_count), 0)::bigint
        )
        FROM platform.services_availability_5m
        WHERE bucket >= now() - interval '1 hour' AND service_name = ANY($1)
        """,
        [names]
      )

    assert %{"total" => 4, "available" => 3, "unavailable" => 3} = payload
  end

  test "ServiceHealth.summary reports distinct active plugin services with exact availability parity",
       %{unique: unique} do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    # Insert synthetic service_state rows:
    # 2 distinct service identities (svc-x and svc-y).
    # svc-x has two gateway rows (one active winner, one inactive).
    # svc-y is active and unavailable.
    state_rows = [
      %{
        id: Ecto.UUID.generate(),
        agent_id: "agent-test-#{unique}",
        gateway_id: "gw-1-#{unique}",
        partition: "default",
        service_type: "plugin",
        service_name: "svc-x-#{unique}",
        available: true,
        state: "active",
        last_observed_at: now,
        inserted_at: now,
        updated_at: now
      },
      %{
        id: Ecto.UUID.generate(),
        agent_id: "agent-test-#{unique}",
        gateway_id: "gw-2-#{unique}",
        partition: "default",
        service_type: "plugin",
        service_name: "svc-x-#{unique}",
        available: true,
        state: "inactive",
        last_observed_at: DateTime.shift(now, minute: -1),
        inserted_at: now,
        updated_at: now
      },
      %{
        id: Ecto.UUID.generate(),
        agent_id: "agent-test-#{unique}",
        gateway_id: "gw-1-#{unique}",
        partition: "default",
        service_type: "plugin",
        service_name: "svc-y-#{unique}",
        available: false,
        state: "active",
        last_observed_at: now,
        inserted_at: now,
        updated_at: now
      }
    ]

    {3, _} = Repo.insert_all("service_state", state_rows, prefix: "platform")

    summary = ServiceHealth.summary()

    assert summary.total >= 2
    assert summary.available + summary.unavailable == summary.total
    assert summary.availability_pct >= 0.0 and summary.availability_pct <= 100.0
    assert %DateTime{} = summary.last_updated

    # In-memory summary matches exact distinct identities
    memory_summary = ServiceHealth.summary_from_states(state_rows)
    assert memory_summary.total == 2
    assert memory_summary.available == 1
    assert memory_summary.unavailable == 1
    assert memory_summary.availability_pct == 50.0
    assert memory_summary.available + memory_summary.unavailable == memory_summary.total
  end
end
