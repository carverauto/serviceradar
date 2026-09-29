defmodule ServiceRadar.SweepJobs.SweepIngestionConcurrencyDbTest do
  @moduledoc """
  Sweep results are ingested by several workers at once
  (`ServiceRadar.SweepJobs.Ingestion`). Two agents sweeping the same devices
  therefore update the same `ocsf_devices` and `device_agent_availability`
  rows from independent connections. The ingestor logs and swallows statement
  failures, so a deadlock or lock failure shows up as a logged error and a
  missing write rather than as an exception; both are asserted here.
  """

  use ServiceRadar.DataCase, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepResultsIngestor
  alias ServiceRadar.TestSupport

  @moduletag :integration
  @moduletag sandbox: :unboxed

  @device_count 60
  @rounds 4
  @partition "default"

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:test)
    suffix = Ash.UUID.generate()
    uids = for index <- 1..@device_count, do: "sweep-concurrency-#{suffix}-#{index}"
    ips = Enum.map(uids, &unique_ip/1)

    for {uid, ip} <- Enum.zip(uids, ips) do
      {:ok, _device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: uid,
            ip: ip,
            hostname: uid,
            discovery_sources: ["netbox"],
            tags: %{},
            is_available: false
          },
          actor: actor
        )
        |> Ash.create()
    end

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{name: "sweep-concurrency-#{suffix}", partition: @partition, agent_ids: []},
        actor: actor
      )
      |> Ash.create()

    agents = ["agent-a-#{suffix}", "agent-b-#{suffix}"]

    on_exit(fn -> cleanup(uids, group.id) end)

    {:ok, actor: actor, uids: uids, ips: ips, group: group, agents: agents}
  end

  test "two agents ingesting the same devices concurrently both complete", ctx do
    [agent_a, agent_b] = ctx.agents

    log =
      capture_log(fn ->
        tasks = [
          # Agent A sees every device and walks them in order.
          Task.async(fn -> ingest_rounds(ctx, agent_a, ctx.ips, fn _index -> true end) end),
          # Agent B walks them in reverse and sees every other device.
          Task.async(fn ->
            ingest_rounds(ctx, agent_b, Enum.reverse(ctx.ips), fn index -> rem(index, 2) == 0 end)
          end)
        ]

        results = Task.await_many(tasks, 120_000)

        for rounds <- results, result <- rounds do
          assert {:ok, stats} = result
          assert stats.hosts_total == @device_count
        end
      end)

    for message <- [
          "Failed to mark devices available",
          "Failed to apply hysteresis",
          "Failed to upsert per-agent availability",
          "deadlock"
        ] do
      refute log =~ message
    end

    rows =
      Repo.query!(
        """
        SELECT agent_id, count(*)::int, count(*) FILTER (WHERE is_available)::int
        FROM platform.device_agent_availability
        WHERE device_uid = ANY($1)
        GROUP BY agent_id
        """,
        [ctx.uids]
      ).rows

    assert Enum.sort(rows) ==
             Enum.sort([
               [agent_a, @device_count, @device_count],
               [agent_b, @device_count, div(@device_count, 2)]
             ])

    # Agent A reported every device available in every round, so every device is
    # canonically available regardless of how the two agents interleaved.
    %{rows: [[available]]} =
      Repo.query!(
        "SELECT count(*)::int FROM platform.ocsf_devices WHERE uid = ANY($1) AND is_available",
        [ctx.uids]
      )

    assert available == @device_count

    %{rows: completed} =
      Repo.query!(
        """
        SELECT agent_id, count(*)::int
        FROM platform.sweep_group_executions
        WHERE sweep_group_id = $1 AND status = 'completed'
        GROUP BY agent_id
        """,
        [Ecto.UUID.dump!(ctx.group.id)]
      )

    # Each agent's executions are superseded only by that agent's own later
    # execution; the last round of each agent must be complete.
    assert Enum.sort(Enum.map(completed, &hd/1)) == Enum.sort(ctx.agents)
  end

  defp ingest_rounds(ctx, agent_id, ips, available?) do
    for _round <- 1..@rounds do
      checked_at = DateTime.to_iso8601(DateTime.utc_now())

      results =
        ips
        |> Enum.with_index()
        |> Enum.map(fn {ip, index} ->
          if available?.(index) do
            %{
              "host_ip" => ip,
              "available" => true,
              "icmp_response_time_ns" => 1_000_000,
              "port_results" => [],
              "last_sweep_time" => checked_at
            }
          else
            %{
              "host_ip" => ip,
              "available" => false,
              "port_results" => [],
              "error" => "timeout",
              "last_sweep_time" => checked_at
            }
          end
        end)

      SweepResultsIngestor.ingest_results(results, Ash.UUID.generate(),
        actor: ctx.actor,
        sweep_group_id: ctx.group.id,
        agent_id: agent_id,
        authenticated_agent_id: agent_id,
        authenticated_partition_id: @partition
      )
    end
  end

  # Documentation-range (2001:db8::/32) addresses derived from the unique uid,
  # so concurrent test runs never collide on the active-IP unique index.
  defp unique_ip(seed) do
    digest = binary_part(:crypto.hash(:sha256, seed), 0, 8)
    [g1, g2, g3, g4] = for <<group::size(16) <- digest>>, do: group
    {0x2001, 0x0DB8, g1, g2, g3, g4, 0, 1} |> :inet.ntoa() |> to_string()
  end

  defp cleanup(uids, group_id) do
    group_id = Ecto.UUID.dump!(group_id)

    Repo.query!("DELETE FROM platform.device_agent_availability WHERE device_uid = ANY($1)", [
      uids
    ])

    Repo.query!(
      """
      DELETE FROM platform.sweep_host_results
      WHERE execution_id IN (SELECT id FROM platform.sweep_group_executions WHERE sweep_group_id = $1)
      """,
      [group_id]
    )

    Repo.query!("DELETE FROM platform.sweep_group_executions WHERE sweep_group_id = $1", [
      group_id
    ])

    Repo.query!("DELETE FROM platform.sweep_groups WHERE id = $1", [group_id])
    Repo.query!("DELETE FROM platform.ocsf_devices WHERE uid = ANY($1)", [uids])
  end
end
