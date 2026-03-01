defmodule ServiceRadar.Plugins.PolicyAssignmentReconcilerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Plugins.PolicyAssignmentReconciler

  defmodule ResolverV1 do
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
    @behaviour ServiceRadar.Plugins.PolicyAssignmentReconciler

    def start_link do
      Agent.start_link(fn -> %{} end, name: __MODULE__)
    end

    def stop do
      if Process.whereis(__MODULE__), do: Agent.stop(__MODULE__)
      :ok
    end

    @impl true
    def list_policy_assignments(policy_id, _actor) do
      rows =
        Agent.get(__MODULE__, fn state ->
          state
          |> Map.values()
          |> Enum.filter(&(&1.policy_id == policy_id and &1.source == :policy))
        end)

      {:ok, rows}
    end

    @impl true
    def create_assignment(spec, _actor) do
      record = spec_to_record(spec)
      Agent.update(__MODULE__, &Map.put(&1, record.source_key, record))
      {:ok, record}
    end

    @impl true
    def update_assignment(existing, spec, _actor) do
      record = spec_to_record(spec, existing)
      Agent.update(__MODULE__, &Map.put(&1, record.source_key, record))
      {:ok, record}
    end

    @impl true
    def disable_assignment(existing, _actor) do
      disabled = Map.put(existing, :enabled, false)
      Agent.update(__MODULE__, &Map.put(&1, disabled.source_key, disabled))
      {:ok, disabled}
    end

    defp spec_to_record(spec, existing \\ %{}) do
      %{
        id: Map.get(existing, :id, Ecto.UUID.generate()),
        agent_uid: spec.agent_uid,
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
               generated_at: "2026-02-21T23:30:00Z"
             )

    assert second.upserted == 0
    assert second.unchanged == 1
    assert second.disabled == 0

    assert {:ok, third} =
             PolicyAssignmentReconciler.reconcile(policy, [],
               resolver: ResolverV2,
               store: MemoryStore,
               generated_at: "2026-02-21T23:31:00Z"
             )

    assert third.upserted == 1
    assert third.unchanged == 0
    assert third.disabled == 1
  end
end
