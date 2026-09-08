defmodule ServiceRadar.Plugins.PolicyAssignmentReconcilerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Plugins.PolicyAssignmentReconciler

  defmodule ResolverV1 do
    @moduledoc false
    def resolve(_input_defs, _opts) do
      {:ok,
       [
         %{
           name: "devices",
           entity: "devices",
           query: "in:devices vendor:AXIS",
           rows: [%{"uid" => "sr:device:1", "agent_id" => "agent-a", "ip" => "10.0.0.1"}]
         }
       ]}
    end
  end

  defmodule ResolverV2 do
    @moduledoc false
    def resolve(_input_defs, _opts) do
      {:ok,
       [
         %{
           name: "devices",
           entity: "devices",
           query: "in:devices vendor:AXIS",
           rows: [%{"uid" => "sr:device:2", "agent_id" => "agent-a", "ip" => "10.0.0.2"}]
         }
       ]}
    end
  end

  defmodule MemoryStore do
    @moduledoc false
    @behaviour PolicyAssignmentReconciler

    def start_link do
      Agent.start_link(fn -> %{} end, name: __MODULE__)
    end

    def stop do
      if pid = Process.whereis(__MODULE__) do
        try do
          Agent.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end

      :ok
    end

    @impl true
    def list_policy_assignments(policy_id, _actor, opts) do
      partition_id = Keyword.get(opts, :partition_id)

      rows =
        Agent.get(__MODULE__, fn state ->
          state
          |> Map.values()
          |> Enum.filter(fn row ->
            row.policy_id == policy_id and row.source == :policy and
              (is_nil(partition_id) or row.partition_id == partition_id)
          end)
        end)

      {:ok, rows}
    end

    @impl true
    def create_assignment(spec, _actor) do
      record = spec_to_record(spec)
      Agent.update(__MODULE__, &Map.put(&1, {record.partition_id, record.source_key}, record))
      {:ok, record}
    end

    @impl true
    def update_assignment(existing, spec, _actor) do
      record = spec_to_record(spec, existing)
      Agent.update(__MODULE__, &Map.put(&1, {record.partition_id, record.source_key}, record))
      {:ok, record}
    end

    @impl true
    def disable_assignment(existing, _actor) do
      disabled = Map.put(existing, :enabled, false)

      Agent.update(
        __MODULE__,
        &Map.put(&1, {disabled.partition_id, disabled.source_key}, disabled)
      )

      {:ok, disabled}
    end

    @impl true
    def find_enabled_assignment(partition_id, agent_uid, plugin_package_id, _actor) do
      record =
        Agent.get(__MODULE__, fn state ->
          state
          |> Map.values()
          |> Enum.find(
            &(&1.partition_id == partition_id and &1.agent_uid == agent_uid and
                &1.plugin_package_id == plugin_package_id and
                &1.enabled)
          )
        end)

      {:ok, record}
    end

    def rows, do: Agent.get(__MODULE__, &Map.values/1)

    def put_row(record) do
      Agent.update(__MODULE__, &Map.put(&1, {record.partition_id, record.source_key}, record))
    end

    defp spec_to_record(spec, existing \\ %{}) do
      %{
        id: Map.get(existing, :id, Ecto.UUID.generate()),
        agent_uid: spec.agent_uid,
        partition_id: spec.partition_id,
        plugin_package_id: spec.plugin_package_id,
        source: :policy,
        source_key: spec.assignment_key,
        policy_id: spec.metadata["policy_id"],
        enabled: spec.enabled,
        interval_seconds: spec.interval_seconds,
        timeout_seconds: spec.timeout_seconds,
        params: spec.params
      }
    end
  end

  defmodule DriftedStore do
    @moduledoc false
    @behaviour PolicyAssignmentReconciler

    # Reproduces production assignment drift: an enabled assignment for the same
    # (agent, package) already exists under an OLDER policy_id, so the current
    # policy's list_policy_assignments/3 returns nothing and create_assignment
    # collides with NoDuplicateEnabledAssignment. The reconciler must adopt
    # (update) the existing row, not duplicate it.
    def start_link(existing) do
      Agent.start_link(fn -> %{existing: existing, adopted: nil, created: 0} end,
        name: __MODULE__
      )
    end

    def stop do
      if pid = Process.whereis(__MODULE__) do
        try do
          Agent.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end

      :ok
    end

    def adopted, do: Agent.get(__MODULE__, & &1.adopted)
    def created, do: Agent.get(__MODULE__, & &1.created)

    @impl true
    def list_policy_assignments(_policy_id, _actor, _opts), do: {:ok, []}

    @impl true
    def create_assignment(_spec, _actor) do
      Agent.update(__MODULE__, &%{&1 | created: &1.created + 1})

      {:error,
       %Ash.Error.Invalid{
         errors: [
           %Ash.Error.Changes.InvalidAttribute{
             field: :plugin_package_id,
             message: "plugin is already enabled for this agent"
           }
         ]
       }}
    end

    @impl true
    def find_enabled_assignment(_partition_id, _agent_uid, _plugin_package_id, _actor) do
      {:ok, Agent.get(__MODULE__, & &1.existing)}
    end

    @impl true
    def update_assignment(existing, spec, _actor) do
      adopted = %{
        existing
        | source_key: spec.assignment_key,
          policy_id: spec.metadata["policy_id"],
          params: spec.params,
          enabled: spec.enabled
      }

      Agent.update(__MODULE__, &%{&1 | adopted: adopted})
      {:ok, adopted}
    end

    @impl true
    def disable_assignment(assignment, _actor), do: {:ok, Map.put(assignment, :enabled, false)}
  end

  setup do
    {:ok, _pid} = MemoryStore.start_link()

    on_exit(fn ->
      MemoryStore.stop()
    end)

    :ok
  end

  test "reconcile is idempotent and disables stale assignments" do
    policy = %{
      policy_id: "policy-1",
      policy_version: 1,
      plugin_package_id: Ecto.UUID.generate(),
      params_template: %{"collect_events" => true},
      interval_seconds: 30,
      timeout_seconds: 8,
      enabled: true
    }

    assert {:ok, first} =
             PolicyAssignmentReconciler.reconcile(policy, [],
               resolver: ResolverV1,
               store: MemoryStore,
               partition_resolver: fn "agent-a" -> {:ok, "farm01"} end,
               generated_at: "2026-02-21T23:30:00Z"
             )

    assert first.upserted == 1
    assert first.unchanged == 0
    assert first.disabled == 0
    assert first.desired_assignments == 1

    assert {:ok, second} =
             PolicyAssignmentReconciler.reconcile(policy, [],
               resolver: ResolverV1,
               store: MemoryStore,
               partition_resolver: fn "agent-a" -> {:ok, "farm01"} end,
               generated_at: "2026-02-21T23:30:00Z"
             )

    assert second.upserted == 0
    assert second.unchanged == 1
    assert second.disabled == 0

    assert {:ok, third} =
             PolicyAssignmentReconciler.reconcile(policy, [],
               resolver: ResolverV2,
               store: MemoryStore,
               partition_resolver: fn "agent-a" -> {:ok, "farm01"} end,
               generated_at: "2026-02-21T23:31:00Z"
             )

    assert third.upserted == 1
    assert third.unchanged == 0
    assert third.disabled == 0
  end

  test "converges a drifted enabled assignment in place instead of duplicating" do
    package_id = Ecto.UUID.generate()

    existing = %{
      id: Ecto.UUID.generate(),
      agent_uid: "agent-a",
      partition_id: "farm01",
      plugin_package_id: package_id,
      source: :policy,
      source_key: "drifted-old-source-key",
      policy_id: "policy-OLD",
      enabled: true,
      params: %{}
    }

    {:ok, _pid} = DriftedStore.start_link(existing)
    on_exit(fn -> DriftedStore.stop() end)

    policy = %{
      policy_id: "policy-NEW",
      policy_version: 1,
      plugin_package_id: package_id,
      params_template: %{"collect_events" => true},
      interval_seconds: 30,
      timeout_seconds: 8,
      enabled: true
    }

    assert {:ok, stats} =
             PolicyAssignmentReconciler.reconcile(policy, [],
               resolver: ResolverV1,
               store: DriftedStore,
               partition_resolver: fn "agent-a" -> {:ok, "farm01"} end,
               generated_at: "2026-02-21T23:30:00Z"
             )

    # The create collided once, then the existing row was adopted — not a second
    # enabled assignment created.
    assert DriftedStore.created() == 1
    assert stats.upserted == 1

    adopted = DriftedStore.adopted()
    assert adopted
    assert adopted.policy_id == "policy-NEW"
    assert adopted.source_key != "drifted-old-source-key"
    assert adopted.enabled == true
  end

  test "same agent UID rebind creates a new partition-bound row and disables the old row" do
    policy = %{
      policy_id: "policy-rebind",
      policy_version: 1,
      plugin_package_id: Ecto.UUID.generate(),
      params_template: %{},
      enabled: true
    }

    assert {:ok, _} =
             PolicyAssignmentReconciler.reconcile(policy, [],
               resolver: ResolverV1,
               store: MemoryStore,
               partition_resolver: fn "agent-a" -> {:ok, "farm01"} end,
               generated_at: "2026-07-13T20:00:00Z"
             )

    assert {:ok, stats} =
             PolicyAssignmentReconciler.reconcile(policy, [],
               resolver: ResolverV1,
               store: MemoryStore,
               partition_resolver: fn "agent-a" -> {:ok, "tonka01"} end,
               generated_at: "2026-07-13T20:00:00Z"
             )

    assert stats.upserted == 1
    assert stats.disabled == 1

    rows = MemoryStore.rows()
    assert Enum.count(rows, &(&1.agent_uid == "agent-a")) == 2
    assert rows |> Enum.map(& &1.source_key) |> Enum.uniq() |> length() == 1
    assert Enum.any?(rows, &(&1.partition_id == "farm01" and &1.enabled == false))
    assert Enum.any?(rows, &(&1.partition_id == "tonka01" and &1.enabled == true))
  end

  test "expected recovery partition rejects a changed live session before any assignment write" do
    policy = %{
      policy_id: "policy-recovery-partition-guard",
      policy_version: 1,
      plugin_package_id: Ecto.UUID.generate(),
      params_template: %{},
      enabled: true
    }

    # Recovery observed farm01 before entering its guarded transaction, but the
    # reconcile-time resolver sees the same agent authenticated in tonka01.
    # Do not create, update, adopt, or retract an assignment in that case.
    assert {:error, errors} =
             PolicyAssignmentReconciler.reconcile(policy, [],
               resolver: ResolverV1,
               store: MemoryStore,
               expected_partition_id: "farm01",
               partition_resolver: fn "agent-a" -> {:ok, "tonka01"} end,
               generated_at: "2026-07-15T20:00:00Z"
             )

    assert Enum.any?(errors, &String.contains?(&1, "authenticated_agent_partition_changed"))
    assert MemoryStore.rows() == []
  end

  test "expected recovery partition permits the preflight session" do
    policy = %{
      policy_id: "policy-recovery-partition-control",
      policy_version: 1,
      plugin_package_id: Ecto.UUID.generate(),
      params_template: %{},
      enabled: true
    }

    assert {:ok, %{upserted: 1}} =
             PolicyAssignmentReconciler.reconcile(policy, [],
               resolver: ResolverV1,
               store: MemoryStore,
               expected_partition_id: "farm01",
               partition_resolver: fn "agent-a" -> {:ok, "farm01"} end,
               generated_at: "2026-07-15T20:00:00Z"
             )

    assert [%{agent_uid: "agent-a", partition_id: "farm01", enabled: true}] =
             MemoryStore.rows()
  end

  test "recovery partition scope leaves a same-UID assignment in another partition untouched" do
    policy = %{
      policy_id: "policy-recovery-partition-scope",
      policy_version: 1,
      plugin_package_id: Ecto.UUID.generate(),
      params_template: %{},
      enabled: true
    }

    # Establish the current farm01 assignment through the normal planner so its
    # source key exactly matches the recovery plan. Then inject a separately
    # active, stale tonka01 row for the same agent UID. The recovery's native
    # agent scope alone is insufficient: both rows have agent-a.
    assert {:ok, _} =
             PolicyAssignmentReconciler.reconcile(policy, [],
               resolver: ResolverV1,
               store: MemoryStore,
               partition_resolver: fn "agent-a" -> {:ok, "farm01"} end,
               generated_at: "2026-07-15T21:00:00Z"
             )

    [farm_assignment] = MemoryStore.rows()

    tonka_assignment = %{
      farm_assignment
      | id: Ecto.UUID.generate(),
        partition_id: "tonka01",
        source_key: "stale-tonka01-source",
        interval_seconds: 987,
        timeout_seconds: 654,
        params: %{"must_remain" => "tonka01"}
    }

    MemoryStore.put_row(tonka_assignment)

    assert {:ok, stats} =
             PolicyAssignmentReconciler.reconcile(policy, [],
               resolver: ResolverV1,
               store: MemoryStore,
               agent_scope: ["agent-a"],
               expected_partition_id: "farm01",
               partition_resolver: fn "agent-a" -> {:ok, "farm01"} end,
               generated_at: "2026-07-15T21:01:00Z"
             )

    assert stats.unchanged == 1
    assert stats.disabled == 0

    assert ^tonka_assignment =
             Enum.find(MemoryStore.rows(), &(&1.id == tonka_assignment.id))
  end
end
