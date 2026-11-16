defmodule ServiceRadar.SweepJobs.LeaseWindowCommitSerialDbTest do
  @moduledoc """
  Runs serially (see the `serial` disposition): it counts this process's Repo
  queries, so any concurrent test issuing queries through the same process
  filter would pollute the count. A full 7-day horizon on a 5-minute schedule
  holds ~2,016 slots; the measured push is a refresh that re-pushes the whole
  carried window at once. Evidence entries are built for every slot and
  committed through the set-based `commit_issuance/1` in 1,024-entry chunks:
  four transactions of a fixed handful of statements for the whole window,
  where the per-entry commit ran seven or eight statements per entry (about
  28,000 for this window) and failed the 15s checkout timeout on a slow
  database. Minting is bounded the same way: a pass inserts its new slots a
  few hundred rows per statement instead of one statement per slot.

  The test is unboxed (`sandbox: :unboxed`) so every `Repo.transaction` is a
  real commit, and it deletes every row it creates in `on_exit`. Counting is
  client-side through Ecto telemetry, filtered to the test process, following
  the advisory feed loader integration test's `capture_queries` pattern.

  `pg_stat_database` is deliberately NOT the counter here: inside the sandbox
  every inner transaction is a savepoint (a probe measured a delta of 0 across
  ~50 real chunk commits), and the fixture server's stats collector lags
  commits by tens of seconds, so a server-side delta can neither prove the new
  path cheap nor catch a regression to the old one.
  """

  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.PipelineSetting
  alias Serviceradar.Edge.V1.SweepLeaseV1
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ExecutionSlots
  alias ServiceRadar.SweepJobs.LeaseDelivery
  alias ServiceRadar.SweepJobs.LeasePass
  alias ServiceRadar.SweepJobs.ProducerAssignments
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.TestSupport

  @moduletag :integration

  @key IssuerKey.from_seed(:binary.copy(<<0x5A>>, 32))
  @contract %{
    contract_id: "serviceradar.sweep.observation",
    contract_version: 1,
    contract_bundle_sha256: :crypto.hash(:sha256, "bundle"),
    registry_epoch: 1,
    registry_snapshot_sha256: :crypto.hash(:sha256, "snapshot"),
    cost_model_version: 1,
    max_projected_row_count: 10_000,
    max_projected_write_bytes: 20_480_000
  }

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  @tag timeout: 1_200_000
  @tag sandbox: :unboxed
  test "a 2,016-slot window mints and re-pushes in a bounded handful of statements" do
    suffix = System.unique_integer([:positive])
    admin = %{id: Ash.UUID.generate(), email: "admin-#{suffix}@example.test", role: :admin}

    assert {:ok, partition} =
             Partition
             |> Ash.Changeset.for_create(:create, %{name: "win-#{suffix}", slug: "win-#{suffix}"},
               actor: admin
             )
             |> Ash.create()

    device_uid = "device-win-#{suffix}"

    assert {:ok, _} =
             Device
             |> Ash.Changeset.for_create(
               :create,
               %{
                 uid: device_uid,
                 ip: TestSupport.unique_device_ip(),
                 partition: partition.slug,
                 hostname: "win-#{suffix}"
               },
               actor: admin
             )
             |> Ash.create()

    agent = "agent-win-#{suffix}"

    assert {:ok, _} =
             Agent
             |> Ash.Changeset.for_create(
               :register,
               %{
                 uid: agent,
                 device_uid: device_uid,
                 capabilities: ["sweep_lease_plan_checks:v1"]
               },
               actor: admin
             )
             |> Ash.create()

    assert {:ok, _} =
             PipelineSetting
             |> Ash.Changeset.for_create(
               :upsert,
               %{scope: :partition, scope_key: partition.id, horizon_seconds: 7 * 24 * 3_600},
               actor: admin
             )
             |> Ash.create()

    assert {:ok, group} =
             SweepGroup
             |> Ash.Changeset.for_create(
               :create,
               %{
                 name: "window #{suffix}",
                 partition: partition.slug,
                 interval: "5m",
                 enabled: false,
                 agent_ids: [agent],
                 static_targets: ["192.0.2.0/28", "198.51.100.7"],
                 sweep_modes: ["icmp"]
               },
               actor: admin
             )
             |> Ash.create()

    Repo.query!("UPDATE platform.sweep_groups SET enabled = true WHERE id = $1::uuid", [
      Ecto.UUID.dump!(group.id)
    ])

    group = %{group | enabled: true}
    now = DateTime.utc_now()
    test_pid = self()
    partition_id_bin = Ecto.UUID.dump!(partition.id)

    # Registered first so it runs last: every committed row is gone even when
    # an assertion below fails. Devices (with their agents, ordinals and
    # availability side rows) go through the guarded fixture deleter; the
    # partition goes last because devices reference it.
    on_exit(fn ->
      TestSupport.delete_device_fixtures!([device_uid], fn ->
        delete_sweep_fixtures!(agent, partition, group.id)
      end)

      Repo.delete_all(
        from(p in "partitions",
          where: fragment("? = ?::uuid", p.id, ^partition_id_bin)
        ),
        prefix: "platform"
      )
    end)

    sender = fn agent_id, group_id, payload ->
      send(test_pid, {:pushed, agent_id, group_id, SweepLeaseV1.decode(payload), payload})
      :ok
    end

    delivery = %{authority: %{key: @key, contract: @contract}, sender: sender}

    # A pass mints at most 1,000 slots per assignment, so the horizon takes three pushes.
    # Each push is acknowledged, so later passes take the tail path over the newly minted
    # slots instead of re-pushing the carried window.
    # The first pass mints 1,000 slots and pushes them (2,000 evidence entries).
    {first_pass, _} =
      count_queries(fn -> assert mint_window(group, now, delivery, agent, 1) == 1 end)

    assert mint_window(group, now, delivery, agent, 4) >= 1

    assert {:ok, %{} = assignment} = ProducerAssignments.get(group.id, agent)
    assert {:ok, slots} = ExecutionSlots.list_unrun(assignment.id, now)
    assert length(slots) > 2_000

    later = DateTime.shift(now, second: 1)

    {refresh, result} =
      count_queries(fn ->
        LeasePass.refresh_agent(agent, delivery, later, %{
          group.id => String.duplicate("0", 64)
        })
      end)

    assert {:ok, %{pushed: 1, errors: 0}} = result

    assert_receive {:pushed, _, _, lease, _}, 600_000
    # The re-push carries the whole window: a bare push (a rotated lease, a dropped
    # window) would fail here loudly instead of silently proving nothing.
    assert length(lease.slots) > 2_000

    # Eight commits for the issuance entries (4,032 entries in 512-entry chunks),
    # plus up to eight of the pass's own bookkeeping transactions (record_push,
    # mark_delivered). The per-slot path committed ~2,020 times here and the
    # 64-entry per-entry chunks 63 times.
    assert refresh.commits <= 16
    # Every statement of the refresh, planning and bookkeeping included: eight
    # chunks of at most ten statements plus a fixed set (measured 81). The
    # per-entry commit alone ran about 28,000 for this window.
    assert refresh.statements <= 120
    # Minting 1,000 slots and pushing their 2,000 entries: four 250-row inserts
    # and four issuance chunks plus a fixed set (measured 75), where per-slot
    # inserts and per-entry commits ran about 17,000.
    assert first_pass.statements <= 120
  end

  # Counts the queries (and, among them, the commits) this process sends while
  # `fun` runs. Detached before returning, so the cleanup deletes are not counted.
  defp count_queries(fun) do
    test_pid = self()
    counters = :counters.new(2, [])
    handler_id = {__MODULE__, :query_counter, make_ref()}
    telemetry_event = Repo.config() |> Keyword.fetch!(:telemetry_prefix) |> Kernel.++([:query])

    :telemetry.attach(
      handler_id,
      telemetry_event,
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid do
          :counters.add(counters, 1, 1)
          if metadata.query == "commit", do: :counters.add(counters, 2, 1)
        end
      end,
      nil
    )

    try do
      result = fun.()
      {%{statements: :counters.get(counters, 1), commits: :counters.get(counters, 2)}, result}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp mint_window(group, now, delivery, agent, attempts) do
    Enum.reduce_while(1..attempts, 0, fn _, pushed ->
      case LeasePass.reconcile_group(group, now, delivery) do
        %{pushed: 1} ->
          assert_receive {:pushed, _, _, _, _}, 300_000
          assert {:ok, [row]} = LeaseDelivery.list_for_group(group.id)

          assert :ok =
                   LeaseDelivery.record_ack(agent, %{
                     sweep_group_id: group.id,
                     payload_sha256: row.delivered_payload_sha256,
                     installed: true
                   })

          {:cont, pushed + 1}

        %{pushed: 0} = summary ->
          assert %{errors: 0} = summary
          {:halt, pushed}
      end
    end)
  end

  # Deletes the sweep-domain rows the test committed, children before parents.
  # Runs inside `delete_device_fixtures!/2`, before it purges the device: the
  # group (with its cascading slots, assignments, executions and declared
  # targets) must go before the device purge, and the agent row stays for the
  # purge's constraint-driven plan. Evidence rows (keys, issuances, candidates)
  # are content-addressed by target, not by group, but their key embeds this
  # run's agent uid in `trust_namespace`, so they are still exactly
  # identifiable. Keys precede issuances: `keys.selected_issuance_id`
  # references issuances with no cascading delete. Deliveries and group versions
  # carry no cascade and go explicitly.
  defp delete_sweep_fixtures!(agent_uid, partition, group_id) do
    group_id_bin = Ecto.UUID.dump!(group_id)

    keys_for_agent =
      from k in "edge_recovery_assignment_keys",
        where: fragment("?->'trust_namespace'->>1", k.mapping_key) == ^agent_uid,
        select: k.id

    Repo.delete_all(
      from(c in "edge_recovery_assignment_candidates",
        where: c.key_id in subquery(keys_for_agent)
      ),
      prefix: "platform"
    )

    Repo.delete_all(
      from(r in "edge_recovery_assignment_resolutions",
        where: r.key_id in subquery(keys_for_agent)
      ),
      prefix: "platform"
    )

    Repo.delete_all(
      from(k in "edge_recovery_assignment_keys",
        where: fragment("?->'trust_namespace'->>1", k.mapping_key) == ^agent_uid
      ),
      prefix: "platform"
    )

    Repo.delete_all(
      from(i in "edge_recovery_assignment_issuances",
        where: fragment("?->'trust_namespace'->>1", i.mapping_key) == ^agent_uid
      ),
      prefix: "platform"
    )

    Repo.delete_all(
      from(d in "sweep_lease_deliveries",
        where: fragment("? = ?::uuid", d.sweep_group_id, ^group_id_bin)
      ),
      prefix: "platform"
    )

    Repo.delete_all(
      from(v in "sweep_group_versions",
        where: fragment("? = ?::uuid", v.version_source_id, ^group_id_bin)
      ),
      prefix: "platform"
    )

    Repo.delete_all(
      from(g in "sweep_groups",
        where: fragment("? = ?::uuid", g.id, ^group_id_bin)
      ),
      prefix: "platform"
    )

    Repo.delete_all(
      from(p in "edge_pipeline_settings",
        where: p.scope_key == ^partition.id
      ),
      prefix: "platform"
    )

    :ok
  end
end
