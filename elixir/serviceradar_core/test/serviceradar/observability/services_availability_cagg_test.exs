defmodule ServiceRadar.Observability.ServicesAvailabilityCaggTest do
  # The dashboard service card, the service health sparkline and SRQL
  # `rollup_stats:availability` read `platform.services_availability_5m`, which
  # no migration used to create. These tests read it the way those readers do.
  #
  # The view is real time: a bucket newer than its refresh window is computed
  # from `service_status` at query time, so rows this test inserts inside its own
  # transaction are visible. The bucket holding "one minute ago" always ends
  # after the refresh policy's five-minute end offset, so it is never
  # materialized and never hides them.
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Repo

  @moduletag :integration

  setup do
    unique = System.unique_integer([:positive])
    at = DateTime.add(DateTime.utc_now(), -60, :second)

    report = fn service_name, service_type, agent_id, available, offset_seconds ->
      %{
        timestamp: DateTime.add(at, offset_seconds, :second),
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

    {:ok, names: Enum.map(~w(svc-a svc-b svc-c), &"#{&1}-#{unique}")}
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
end
