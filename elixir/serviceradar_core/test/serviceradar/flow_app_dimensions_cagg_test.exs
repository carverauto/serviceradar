defmodule ServiceRadar.FlowAppDimensionsCaggTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Jobs.BootstrapFlowAppDimensionsWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration
  @moduletag sandbox: :unboxed
  @view "platform.ocsf_network_activity_hourly_app_dimensions"
  @start ~U[2037-04-05 12:00:00.000000Z]
  @finish ~U[2037-04-05 13:00:00.000000Z]

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "hourly dimensions preserve nulls and exact sampled counters" do
    fixture = Ecto.UUID.generate()

    on_exit(fn ->
      Repo.query!(
        "DELETE FROM platform.ocsf_network_activity WHERE ocsf_payload->>'fixture' = $1",
        [fixture]
      )

      refresh()
    end)

    rows = [
      {nil, nil, nil, nil, nil, 1},
      {"example", 99, nil, nil, nil, 4},
      {nil, nil, nil, 5, 2, 1},
      {"", 0, 0, 7, 3, 0},
      {"example", 6, 443, 11, 4, -2},
      {"example", 6, 443, 13, 5, 10},
      {"example", 6, 443, nil, nil, 2},
      {"example", 17, 443, 3, 1, 4},
      {"example", 6, nil, 17, 6, 2}
    ]

    Enum.each(rows, fn {partition, protocol, port, bytes, packets, sampling} ->
      Repo.query!(
        """
        INSERT INTO platform.ocsf_network_activity
          (time, partition, protocol_num, dst_endpoint_port, bytes_total, packets_total,
           sampling_rate, ocsf_payload)
        VALUES ($1, $2, $3, $4, $5, $6, $7, jsonb_build_object('fixture', $8::text))
        """,
        [DateTime.add(@start, 120), partition, protocol, port, bytes, packets, sampling, fixture]
      )
    end)

    refresh()

    %{rows: actual} =
      Repo.query!(
        """
        SELECT partition, protocol_num, dst_endpoint_port, bytes_total, packets_total, flow_count
        FROM #{@view} WHERE bucket >= $1 AND bucket < $2
        """,
        [@start, @finish]
      )

    assert MapSet.new(actual) ==
             MapSet.new([
               [nil, nil, nil, 5, 2, 2],
               ["example", 99, nil, nil, nil, 1],
               ["", 0, 0, 7, 3, 1],
               ["example", 6, 443, 141, 54, 3],
               ["example", 17, 443, 12, 4, 1],
               ["example", 6, nil, 34, 12, 1]
             ])

    %{rows: raw} =
      Repo.query!(
        """
        SELECT partition, protocol_num, dst_endpoint_port,
               SUM(bytes_total::numeric * GREATEST(COALESCE(sampling_rate, 1), 1))::bigint,
               SUM(packets_total::numeric * GREATEST(COALESCE(sampling_rate, 1), 1))::bigint,
               COUNT(*)::bigint
        FROM platform.ocsf_network_activity WHERE ocsf_payload->>'fixture' = $1
        GROUP BY 1, 2, 3
        """,
        [fixture]
      )

    assert MapSet.new(actual) == MapSet.new(raw)
  end

  test "materialized history has a bounded refresh policy and extended retention" do
    assert %{rows: [[true]]} =
             Repo.query!("""
             SELECT materialized_only FROM timescaledb_information.continuous_aggregates
             WHERE view_schema = 'platform' AND view_name = 'ocsf_network_activity_hourly_app_dimensions'
             """)

    assert %{rows: [[true, true, true]]} =
             Repo.query!("""
             SELECT (j.config->>'start_offset')::interval = interval '3 hours',
                    (j.config->>'end_offset')::interval = interval '1 hour',
                    j.schedule_interval = interval '1 hour'
             FROM timescaledb_information.jobs j
             JOIN _timescaledb_catalog.continuous_agg c
               ON (j.config->>'mat_hypertable_id')::int = c.mat_hypertable_id
             WHERE c.user_view_schema = 'platform'
               AND c.user_view_name = 'ocsf_network_activity_hourly_app_dimensions'
               AND j.proc_name = 'policy_refresh_continuous_aggregate'
             """)

    assert %{rows: [[true]]} =
             Repo.query!("""
             SELECT (j.config->>'drop_after')::interval = interval '395 days'
             FROM timescaledb_information.jobs j
             JOIN _timescaledb_catalog.continuous_agg c
               ON (j.config->>'hypertable_id')::int = c.mat_hypertable_id
             WHERE c.user_view_schema = 'platform'
               AND c.user_view_name = 'ocsf_network_activity_hourly_app_dimensions'
               AND j.proc_name = 'policy_retention'
             """)
  end

  test "bootstrap checkpoints persist on the durable job and completed ranges do not repeat" do
    args = %{
      "start_hour" => DateTime.to_iso8601(@start),
      "next_hour" => DateTime.to_iso8601(@finish)
    }

    assert {:ok, job} =
             args
             |> Oban.Job.new(worker: BootstrapFlowAppDimensionsWorker, queue: :maintenance)
             |> Oban.insert()

    on_exit(fn -> Repo.query!("DELETE FROM platform.oban_jobs WHERE id = $1", [job.id]) end)

    assert :ok = BootstrapFlowAppDimensionsWorker.run(job)
    persisted = Repo.get!(Oban.Job, job.id, prefix: "platform")
    assert persisted.args["next_hour"] == persisted.args["start_hour"]

    assert :ok =
             BootstrapFlowAppDimensionsWorker.run(persisted,
               query: fn sql, params, opts ->
                 refute sql =~ "refresh_continuous_aggregate"
                 Repo.query(sql, params, opts)
               end
             )
  end

  test "partial bootstrap stays contiguous with the recent policy and preserves raw edge totals" do
    fixture = "bootstrap-#{Ecto.UUID.generate()}"
    first = ~U[2037-04-06 00:00:00Z]
    finish = DateTime.add(first, 6 * 3_600)

    on_exit(fn ->
      Repo.query!("DELETE FROM platform.ocsf_network_activity WHERE partition = $1", [fixture])

      Repo.query!(
        "CALL refresh_continuous_aggregate('#{@view}', $1::timestamptz, $2::timestamptz)",
        [first, finish]
      )
    end)

    for hour <- 0..5 do
      Repo.query!(
        """
        INSERT INTO platform.ocsf_network_activity
          (time, partition, protocol_num, dst_endpoint_port, bytes_total, packets_total,
           sampling_rate, ocsf_payload)
        VALUES ($1, $2, 6, 443, $3, 1, 2, '{}'::jsonb)
        """,
        [DateTime.add(first, hour * 3_600 + 120), fixture, hour + 1]
      )
    end

    # Model the normal policy running before the bootstrap's first step.
    Repo.query!(
      "CALL refresh_continuous_aggregate('#{@view}', $1::timestamptz, $2::timestamptz)",
      [DateTime.add(finish, -3 * 3_600), DateTime.add(finish, -3_600)]
    )

    args = %{
      "start_hour" => DateTime.to_iso8601(first),
      "next_hour" => DateTime.to_iso8601(finish)
    }

    Enum.reduce(1..6, args, fn step, args ->
      result =
        BootstrapFlowAppDimensionsWorker.run(%Oban.Job{args: args},
          checkpoint: fn _, next ->
            send(self(), {:progress, next})
            {:ok, %Oban.Job{args: next}}
          end
        )

      assert result == if(step == 6, do: :ok, else: {:snooze, 1})
      assert_receive {:progress, next}
      assert_bootstrap_coverage(fixture)
      next
    end)
  end

  defp assert_bootstrap_coverage(fixture) do
    assert %{rows: [[42, 12, 6]]} =
             Repo.query!(
               """
               WITH covered AS (
                 SELECT min(bucket) AS first, max(bucket) + interval '1 hour' AS last,
                        sum(bytes_total)::bigint AS bytes, sum(packets_total)::bigint AS packets,
                        sum(flow_count)::bigint AS flows
                 FROM #{@view} WHERE partition = $1
               ), edges AS (
                 SELECT sum(bytes_total * sampling_rate)::bigint AS bytes,
                        sum(packets_total * sampling_rate)::bigint AS packets, count(*)::bigint AS flows
                 FROM platform.ocsf_network_activity, covered
                 WHERE partition = $1 AND (time < covered.first OR time >= covered.last)
               )
               SELECT coalesce(covered.bytes, 0) + coalesce(edges.bytes, 0),
                      coalesce(covered.packets, 0) + coalesce(edges.packets, 0),
                      coalesce(covered.flows, 0) + coalesce(edges.flows, 0)
               FROM covered, edges
               """,
               [fixture]
             )
  end

  defp refresh do
    Repo.query!(
      "CALL refresh_continuous_aggregate('#{@view}', $1::timestamptz, $2::timestamptz)",
      [@start, @finish]
    )
  end
end
