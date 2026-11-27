defmodule ServiceRadar.Edge.EdgeLedgerRetentionWorkerDbTest do
  @moduledoc """
  Database integration tests for `ServiceRadar.Edge.EdgeLedgerRetentionWorker`:
  verifies that rows past the retention horizon are deleted across all four edge
  ledger and delivery-slot tables, rows inside the horizon are kept, and slots
  belonging to an undrained registry epoch (`state = 'draining'`) are kept until
  the epoch retires.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ContractBundle
  alias ServiceRadar.Edge.ContractCatalog
  alias ServiceRadar.Edge.ContractRegistry
  alias ServiceRadar.Edge.ContractRegistryEpoch
  alias ServiceRadar.Edge.EdgeLedgerRetentionWorker
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.LedgerCoverage
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ExecutionSlots
  alias ServiceRadar.SweepJobs.ProducerAssignments
  alias ServiceRadar.SweepJobs.SweepGroup

  @moduletag :integration

  @key IssuerKey.from_seed(:binary.copy(<<0x42>>, 32))

  defp release(:a), do: ContractBundle.derive(ContractCatalog.entries())

  defp release(:b) do
    ContractCatalog.entries()
    |> List.update_at(0, &%{&1 | projection_revision: 2})
    |> ContractBundle.derive()
  end

  defp readiness(core_releases) do
    %{
      core_nodes:
        Enum.map(core_releases, fn {node, rel} ->
          %{node: node, snapshot_sha256: release(rel).snapshot_sha256}
        end),
      unreachable_nodes: [],
      gateways: []
    }
  end

  defp insert_record_bundle!(opts) do
    network_scope_id = Keyword.get_lazy(opts, :network_scope_id, &Ecto.UUID.bingenerate/0)
    event_id = Keyword.get_lazy(opts, :event_id, &Ecto.UUID.bingenerate/0)
    spool_id = Keyword.get_lazy(opts, :spool_id, &Ecto.UUID.bingenerate/0)
    execution_id = Keyword.get_lazy(opts, :execution_id, &Ecto.UUID.bingenerate/0)
    sequence = Keyword.get(opts, :sequence, System.unique_integer([:positive, :monotonic]))
    inserted_at = Keyword.fetch!(opts, :inserted_at)
    seed = :erlang.term_to_binary({network_scope_id, event_id, sequence})
    semantic_sha256 = :crypto.hash(:sha256, "semantic:" <> seed)
    record_sha256 = :crypto.hash(:sha256, "record:" <> seed)

    Repo.query!(
      """
      INSERT INTO platform.event_ledger
        (network_scope_id, event_id, semantic_envelope_sha256, record_sha256, inserted_at)
      VALUES ($1::uuid, $2::uuid, $3::bytea, $4::bytea, $5)
      """,
      [network_scope_id, event_id, semantic_sha256, record_sha256, inserted_at]
    )

    Repo.query!(
      """
      INSERT INTO platform.edge_delivery_slots
        (network_scope_id, authenticated_agent_id, spool_id, sequence,
         record_sha256, event_id, semantic_envelope_sha256, inserted_at)
      VALUES ($1::uuid, $2::bytea, $3::uuid, $4::bigint, $5::bytea, $6::uuid, $7::bytea, $8)
      """,
      [
        network_scope_id,
        "agent-synthetic-retention",
        spool_id,
        sequence,
        record_sha256,
        event_id,
        semantic_sha256,
        inserted_at
      ]
    )

    Repo.query!(
      """
      INSERT INTO platform.edge_sweep_batch_slots
        (network_scope_id, execution_id, execution_shard, assignment_epoch, batch_sequence,
         event_id, semantic_envelope_sha256, projected_row_count, committed_row_count, inserted_at)
      VALUES ($1::uuid, $2::uuid, 0, 1, $3::bigint, $4::uuid, $5::bytea, 1, 1, $6)
      """,
      [network_scope_id, execution_id, sequence, event_id, semantic_sha256, inserted_at]
    )

    %{
      network_scope_id: network_scope_id,
      event_id: event_id,
      spool_id: spool_id,
      execution_id: execution_id,
      sequence: sequence
    }
  end

  defp bundle_exists?(%{network_scope_id: scope_id, event_id: event_id}) do
    %{
      event_ledger:
        row_exists?(
          "SELECT 1 FROM platform.event_ledger WHERE network_scope_id = $1::uuid AND event_id = $2::uuid",
          [scope_id, event_id]
        ),
      edge_delivery_slots:
        row_exists?(
          "SELECT 1 FROM platform.edge_delivery_slots WHERE network_scope_id = $1::uuid AND event_id = $2::uuid",
          [scope_id, event_id]
        ),
      edge_sweep_batch_slots:
        row_exists?(
          "SELECT 1 FROM platform.edge_sweep_batch_slots WHERE network_scope_id = $1::uuid AND event_id = $2::uuid",
          [scope_id, event_id]
        )
    }
  end

  defp row_exists?(sql, params) do
    case Repo.query!(sql, params) do
      %{rows: [_ | _]} -> true
      %{rows: []} -> false
    end
  end

  defp lease_slot!(slot_start, collection_expires, inserted_at) do
    suffix = System.unique_integer([:positive, :monotonic])
    actor = %{id: Ash.UUID.generate(), email: "operator-#{suffix}@example.test", role: :operator}

    group =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Retention drain #{suffix}",
          partition: "default",
          interval: "15m",
          enabled: false,
          agent_ids: [],
          static_targets: ["192.0.2.0/24"]
        },
        actor: actor
      )
      |> Ash.create!()

    {:ok, assignment} =
      ProducerAssignments.ensure(group.id, "agent-retention-#{suffix}", Ash.UUID.generate())

    {:ok, slot} =
      ExecutionSlots.schedule(assignment, slot_start, collection_expires,
        targets: ["198.51.100.5"],
        check_set_sha256: :crypto.hash(:sha256, "checks-#{suffix}"),
        lease_id: Ash.UUID.generate()
      )

    slot_uuid = Ecto.UUID.dump!(slot.id)

    Repo.query!(
      "UPDATE platform.sweep_execution_slots SET inserted_at = $2 WHERE id = $1::uuid",
      [slot_uuid, inserted_at]
    )

    slot_uuid
  end

  test "deletes rows past the horizon and keeps rows inside the horizon across all three tables" do
    now = DateTime.utc_now()
    horizon = EdgeLedgerRetentionWorker.retention_horizon_seconds()

    expired =
      insert_record_bundle!(inserted_at: DateTime.shift(now, second: -(horizon + 60)))

    fresh =
      insert_record_bundle!(inserted_at: DateTime.shift(now, second: -(horizon - 60)))

    assert :ok = EdgeLedgerRetentionWorker.perform(%Oban.Job{args: %{}})

    assert bundle_exists?(expired) == %{
             event_ledger: false,
             edge_delivery_slots: false,
             edge_sweep_batch_slots: false
           }

    assert bundle_exists?(fresh) == %{
             event_ledger: true,
             edge_delivery_slots: true,
             edge_sweep_batch_slots: true
           }
  end

  test "keeps a slot for a draining epoch even past the horizon, then deletes it once the epoch retires" do
    now = DateTime.utc_now()
    horizon = EdgeLedgerRetentionWorker.retention_horizon_seconds()
    draining_at = DateTime.shift(now, second: -(horizon + 7_200))

    {:ok, _} = ContractRegistry.ensure_epoch(release(:a), @key, draining_at)
    {:ok, %{epoch: candidate}} = ContractRegistry.ensure_epoch(release(:b), @key, draining_at)
    core_on_b = readiness([{"core-1", :b}])

    assert {:ok, {:activated, ^candidate, 1_000_000}} =
             ContractRegistry.evaluate_transition(core_on_b, @key, draining_at)

    # Lease a sweep execution slot within the 3600s lease margin after draining_since
    # whose collection window is still open at `now`, keeping epoch 1_000_000 draining.
    slot_inserted_at = DateTime.shift(draining_at, minute: 30)
    collection_expires = DateTime.shift(now, hour: 1)

    execution_id =
      lease_slot!(DateTime.shift(now, minute: -5), collection_expires, slot_inserted_at)

    draining_bundle =
      insert_record_bundle!(
        execution_id: execution_id,
        inserted_at: slot_inserted_at
      )

    unrelated_expired =
      insert_record_bundle!(inserted_at: DateTime.shift(draining_at, day: -1))

    closed_slot_inserted_at = DateTime.shift(draining_at, day: -2)

    closed_execution_id =
      lease_slot!(
        closed_slot_inserted_at,
        DateTime.shift(closed_slot_inserted_at, hour: 1),
        closed_slot_inserted_at
      )

    closed_slot_expired =
      insert_record_bundle!(
        execution_id: closed_execution_id,
        inserted_at: closed_slot_inserted_at
      )

    # Confirm epoch 1_000_000 is still draining because of the open sweep slot (#6356).
    assert {:ok, :no_candidate} = ContractRegistry.evaluate_transition(core_on_b, @key, now)

    epoch_row =
      Ash.get!(ContractRegistryEpoch, 1_000_000, actor: SystemActor.system(:retention_test))

    assert epoch_row.state == :draining

    assert :ok = EdgeLedgerRetentionWorker.perform(%Oban.Job{args: %{}})

    # The slot for the draining epoch is kept in all four tables despite being past the horizon.
    assert bundle_exists?(draining_bundle) == %{
             event_ledger: true,
             edge_delivery_slots: true,
             edge_sweep_batch_slots: true
           }

    assert bundle_exists?(unrelated_expired) == %{
             event_ledger: false,
             edge_delivery_slots: false,
             edge_sweep_batch_slots: false
           }

    assert bundle_exists?(closed_slot_expired) == %{
             event_ledger: false,
             edge_delivery_slots: false,
             edge_sweep_batch_slots: false
           }

    # Once the slot's collection window closes and the epoch retires, retention deletes the rows.
    Repo.query!(
      "UPDATE platform.sweep_execution_slots SET collection_expires = $2 WHERE id = $1::uuid",
      [execution_id, DateTime.shift(now, minute: -1)]
    )

    assert {:ok, :no_candidate} = ContractRegistry.evaluate_transition(core_on_b, @key, now)

    retired_row =
      Ash.get!(ContractRegistryEpoch, 1_000_000, actor: SystemActor.system(:retention_test))

    assert retired_row.state == :retired

    assert :ok = EdgeLedgerRetentionWorker.perform(%Oban.Job{args: %{}})

    assert bundle_exists?(draining_bundle) == %{
             event_ledger: false,
             edge_delivery_slots: false,
             edge_sweep_batch_slots: false
           }
  end

  test "deletes expired rows in bounded batches without leaving orphaned child slots" do
    now = DateTime.utc_now()
    horizon = EdgeLedgerRetentionWorker.retention_horizon_seconds()
    expired_at = DateTime.shift(now, second: -(horizon + 120))

    b1 = insert_record_bundle!(inserted_at: expired_at)
    b2 = insert_record_bundle!(inserted_at: expired_at)

    # First pass capped at 1 row per table (batch_size: 1, max_batches: 1)
    assert :ok =
             EdgeLedgerRetentionWorker.perform(%Oban.Job{
               args: %{"batch_size" => 1, "max_batches" => 1}
             })

    s1 = bundle_exists?(b1)
    s2 = bundle_exists?(b2)

    # Exactly one of the two batch slots was deleted on the first pass, and whichever
    # batch slot survived kept its delivery slot and event ledger row.
    assert Enum.count([s1.edge_sweep_batch_slots, s2.edge_sweep_batch_slots], & &1) == 1

    for s <- [s1, s2], s.edge_sweep_batch_slots do
      assert s.edge_delivery_slots
      assert s.event_ledger
    end

    # Second pass deletes the remaining expired bundle
    assert :ok =
             EdgeLedgerRetentionWorker.perform(%Oban.Job{
               args: %{"batch_size" => 10, "max_batches" => 5}
             })

    assert bundle_exists?(b1) == %{
             event_ledger: false,
             edge_delivery_slots: false,
             edge_sweep_batch_slots: false
           }

    assert bundle_exists?(b2) == %{
             event_ledger: false,
             edge_delivery_slots: false,
             edge_sweep_batch_slots: false
           }
  end

  defp coverage do
    %{rows: [[complete_since]]} =
      Repo.query!("SELECT complete_since FROM platform.edge_ledger_coverage WHERE id = 1")

    complete_since
  end

  test "ledger coverage advances to the prune cutoff only when ledger rows go, and never backward" do
    # Clear anything already expired so the next pass deletes nothing. The migration seeds
    # complete_since at its own run time minus 30 days, which may already be later than a
    # prune's cutoff (now minus the horizon), so clear the row: absent means "never pruned".
    assert :ok = EdgeLedgerRetentionWorker.perform(%Oban.Job{args: %{}})
    Repo.query!("DELETE FROM platform.edge_ledger_coverage WHERE id = 1")
    assert LedgerCoverage.complete_since() == {:ok, nil}

    # A pass that deletes no ledger rows leaves coverage alone.
    assert :ok = EdgeLedgerRetentionWorker.perform(%Oban.Job{args: %{}})
    assert LedgerCoverage.complete_since() == {:ok, nil}

    horizon = EdgeLedgerRetentionWorker.retention_horizon_seconds()
    before = DateTime.utc_now()
    expired = insert_record_bundle!(inserted_at: DateTime.shift(before, second: -(horizon + 60)))
    assert :ok = EdgeLedgerRetentionWorker.perform(%Oban.Job{args: %{}})
    after_prune = DateTime.utc_now()

    refute bundle_exists?(expired).event_ledger
    # Every ledger row inserted at or after the cutoff is retained, so coverage is created at
    # exactly this prune's cutoff.
    advanced = coverage()
    refute DateTime.before?(advanced, DateTime.shift(before, second: -horizon))
    refute DateTime.after?(advanced, DateTime.shift(after_prune, second: -horizon))
    assert {:ok, advanced} == LedgerCoverage.complete_since()

    # Coverage already later than this pass's cutoff stays where it is.
    later = DateTime.utc_now() |> DateTime.shift(day: -1) |> DateTime.truncate(:microsecond)

    Repo.query!("UPDATE platform.edge_ledger_coverage SET complete_since = $1 WHERE id = 1", [
      later
    ])

    again = insert_record_bundle!(inserted_at: DateTime.shift(before, second: -(horizon + 60)))
    assert :ok = EdgeLedgerRetentionWorker.perform(%Oban.Job{args: %{}})
    refute bundle_exists?(again).event_ledger
    assert coverage() == later

    # Nothing may move it backward.
    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE platform.edge_ledger_coverage SET complete_since = $1 WHERE id = 1",
               [DateTime.shift(later, day: -1)]
             )
  end

  test "prunes ended authority intervals past the late window, never terminal or open ones" do
    now = DateTime.utc_now()
    old = DateTime.shift(now, day: -20)
    recent = DateTime.shift(now, day: -10)

    insert_interval = fn ended_at, reason ->
      assignment_id = Ecto.UUID.generate()

      Repo.query!(
        """
        INSERT INTO platform.edge_authority_history
          (assignment_id, assignment_kind, agent_id, network_scope_id, run_shard,
           authority_epoch, active_from, active_until, ended_reason)
        VALUES ($1::uuid, 'output_grant', 'agent-synthetic-history', $2::uuid, 0, 1, $3, $4, $5)
        """,
        [
          Ecto.UUID.dump!(assignment_id),
          Ecto.UUID.bingenerate(),
          DateTime.shift(now, day: -40),
          ended_at,
          reason
        ]
      )

      assignment_id
    end

    pruned = insert_interval.(old, "epoch_changed")
    compromised = insert_interval.(old, "compromised")
    inside_window = insert_interval.(recent, "epoch_changed")
    certificate_revoked = insert_interval.(old, "certificate_revoked")
    cause_unknown = insert_interval.(old, "revoked_cause_unknown")
    open = insert_interval.(nil, nil)

    assert :ok = EdgeLedgerRetentionWorker.perform(%Oban.Job{args: %{}})

    present? = fn id ->
      row_exists?(
        "SELECT 1 FROM platform.edge_authority_history WHERE assignment_id = $1::uuid",
        [Ecto.UUID.dump!(id)]
      )
    end

    # Past the 14-day window (plus tolerance) an ordinary or compromised interval may go: a
    # record naming it then gets history_unknown, which is AUDIT, never PRIMARY.
    refute present?.(pruned)
    refute present?.(compromised)
    assert present?.(inside_window)
    # Terminal intervals keep their records quarantine-only for good; open ones are current.
    assert present?.(certificate_revoked)
    assert present?.(cause_unknown)
    assert present?.(open)
  end
end
