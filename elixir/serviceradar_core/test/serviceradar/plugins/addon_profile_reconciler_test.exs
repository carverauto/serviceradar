defmodule ServiceRadar.Plugins.AddonProfileReconcilerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Plugins.AddonProfileReconciler

  defmodule ResolverV1 do
    @moduledoc false
    def resolve(_input_defs, _opts) do
      {:ok,
       [
         %{
           name: "targets",
           entity: "devices",
           query: "in:devices hostname:ns*",
           rows: [
             %{"uid" => "sr:device:1", "agent_id" => "agent-a"},
             %{"uid" => "sr:device:2", "agent_uid" => "agent-b"},
             %{"uid" => "sr:device:3"}
           ]
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
           name: "targets",
           entity: "agents",
           query: "in:agents name:agent-*",
           rows: [%{"uid" => "agent-c"}]
         }
       ]}
    end
  end

  defmodule MemoryStore do
    @moduledoc false
    @behaviour AddonProfileReconciler

    def start_link do
      Agent.start_link(fn -> %{assignments: %{}, manual: MapSet.new()} end, name: __MODULE__)
    end

    def stop do
      if Process.whereis(__MODULE__), do: Agent.stop(__MODULE__)
      :ok
    end

    def put_manual(addon_id, agent_uid) do
      Agent.update(__MODULE__, fn state ->
        update_in(state.manual, &MapSet.put(&1, {addon_id, agent_uid}))
      end)
    end

    @impl true
    def list_profile_assignments(profile_id, _actor) do
      rows =
        Agent.get(__MODULE__, fn state ->
          state.assignments
          |> Map.values()
          |> Enum.filter(&(&1.addon_profile_id == profile_id and &1.source == :profile))
        end)

      {:ok, rows}
    end

    @impl true
    def list_manual_assignments(addon_id, agent_uids, _actor) do
      rows =
        Agent.get(__MODULE__, fn state ->
          agent_uids
          |> Enum.filter(&MapSet.member?(state.manual, {addon_id, &1}))
          |> Enum.map(&%{agent_uid: &1, addon_id: addon_id, source: :manual, enabled: true})
        end)

      {:ok, rows}
    end

    @impl true
    def create_assignment(spec, _actor) do
      record = spec_to_record(spec)
      Agent.update(__MODULE__, &put_in(&1.assignments[record.source_key], record))
      {:ok, record}
    end

    @impl true
    def update_assignment(existing, spec, _actor) do
      record = spec_to_record(spec, existing)
      Agent.update(__MODULE__, &put_in(&1.assignments[record.source_key], record))
      {:ok, record}
    end

    @impl true
    def disable_assignment(existing, _actor) do
      disabled = %{existing | enabled: false, profile_reconcile_status: "stale"}
      Agent.update(__MODULE__, &put_in(&1.assignments[disabled.source_key], disabled))
      {:ok, disabled}
    end

    defp spec_to_record(spec, existing \\ %{}) do
      %{
        id: Map.get(existing, :id, Ecto.UUID.generate()),
        agent_uid: spec.agent_uid,
        addon_id: spec.addon_id,
        addon_package_id: spec.addon_package_id,
        source: :profile,
        source_key: spec.assignment_key,
        addon_profile_id: spec.addon_profile_id,
        enabled: spec.enabled,
        params: spec.params,
        args: spec.args,
        profile_reconcile_status: spec.profile_reconcile_status,
        profile_reconcile_error: spec.profile_reconcile_error,
        profile_last_reconciled_at: spec.profile_last_reconciled_at,
        profile_metadata: spec.profile_metadata
      }
    end
  end

  setup do
    {:ok, _pid} = MemoryStore.start_link()
    on_exit(fn -> MemoryStore.stop() end)
    :ok
  end

  test "reconcile is idempotent, skips manual overrides, and disables stale assignments" do
    profile = %{
      id: Ecto.UUID.generate(),
      name: "PowerDNS servers",
      addon_id: "powerdns",
      addon_package_id: Ecto.UUID.generate(),
      target_query: "in:devices hostname:ns*",
      params: %{"api_url" => "http://127.0.0.1:8081"},
      args: ["--collector"],
      priority: 20,
      enabled: true
    }

    MemoryStore.put_manual("powerdns", "agent-b")

    assert {:ok, first} =
             AddonProfileReconciler.reconcile(profile,
               resolver: ResolverV1,
               store: MemoryStore,
               reconciled_at: ~U[2026-06-09 17:00:00Z]
             )

    assert first.matched_rows == 3
    assert first.target_agents == 2
    assert first.skipped_without_agent == 1
    assert first.skipped_manual_overrides == 1
    assert first.desired_assignments == 1
    assert first.upserted == 1
    assert first.unchanged == 0
    assert first.disabled == 0

    assert {:ok, second} =
             AddonProfileReconciler.reconcile(profile,
               resolver: ResolverV1,
               store: MemoryStore,
               reconciled_at: ~U[2026-06-09 17:00:00Z]
             )

    assert second.upserted == 0
    assert second.unchanged == 1
    assert second.disabled == 0

    assert {:ok, third} =
             AddonProfileReconciler.reconcile(%{profile | target_query: "in:agents name:agent-*"},
               resolver: ResolverV2,
               store: MemoryStore,
               reconciled_at: ~U[2026-06-09 17:01:00Z]
             )

    assert third.target_agents == 1
    assert third.upserted == 1
    assert third.unchanged == 0
    assert third.disabled == 1
  end
end
