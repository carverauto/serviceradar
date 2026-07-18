defmodule ServiceRadar.Automation.Ansible.AwxInventorySyncReconcilerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Automation.Ansible.AwxClient
  alias ServiceRadar.Automation.Ansible.AwxInventorySyncReconciler
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Plugins.PolicyAssignmentReconciler
  alias ServiceRadar.Plugins.SecretRefs

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

    def records do
      Agent.get(__MODULE__, & &1)
    end

    @impl true
    def list_policy_assignments(policy_id, _actor, opts) do
      partition_id = Keyword.get(opts, :partition_id)

      rows =
        __MODULE__
        |> Agent.get(&Map.values/1)
        |> Enum.filter(fn row ->
          row.policy_id == policy_id and row.source == :policy and
            (is_nil(partition_id) or row.partition_id == partition_id)
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
      Agent.update(__MODULE__, &Map.delete(&1, existing.source_key))
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

    @impl true
    def find_enabled_assignment(partition_id, agent_uid, plugin_package_id, _actor) do
      record =
        __MODULE__
        |> Agent.get(&Map.values/1)
        |> Enum.find(
          &(&1.partition_id == partition_id and &1.agent_uid == agent_uid and
              &1.plugin_package_id == plugin_package_id and &1.enabled)
        )

      {:ok, record}
    end

    defp spec_to_record(spec, existing \\ %{}) do
      %{
        id: Map.get(existing, :id, Ecto.UUID.generate()),
        partition_id: spec.partition_id,
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
    on_exit(&MemoryStore.stop/0)
    :ok
  end

  test "reconciles one assignment per agent with all reachable controllers" do
    package = %{id: Ecto.UUID.generate(), version: "0.1.1"}

    controllers = [
      controller("ctrl-1", "agent-a", "https://awx-a.example.com", "secret-a",
        name: "AWX A",
        interval: 300
      ),
      controller("ctrl-2", "agent-a", "https://awx-b.example.com", "secret-b",
        name: "AWX B",
        interval: 120,
        metadata: %{"timeout_ms" => 45_000, "insecure_skip_verify" => true}
      ),
      controller("ctrl-3", "agent-b", "https://awx-c.example.com", "secret-c", name: "AWX C")
    ]

    assert {:ok, stats} =
             AwxInventorySyncReconciler.reconcile_controllers(controllers,
               plugin_package: package,
               store: MemoryStore,
               grant_template: &grant_template/1,
               partition_resolver: &partition_for_agent/1
             )

    assert stats.desired_assignments == 2
    records = MemoryStore.records()
    assert map_size(records) == 2

    agent_a = Map.fetch!(records, "ansible:awx-inventory-sync:agent-a")
    assert agent_a.interval_seconds == 120
    assert agent_a.timeout_seconds == 120
    assert [first, second] = agent_a.params["controllers"]
    assert first["controller_id"] == "ctrl-1"
    assert second["controller_id"] == "ctrl-2"
    assert second["insecure_skip_verify"] == true
    refute Map.has_key?(first, "api_token")
    assert first["api_token_secret_ref"] == SecretRefs.network_credential_ref("secret-a")

    assert first["credential_broker"]["credential_secret_ref"] ==
             SecretRefs.network_credential_ref("secret-a")
  end

  test "empty controller set disables stale policy assignments" do
    package = %{id: Ecto.UUID.generate(), version: "0.1.1"}

    assert {:ok, _} =
             AwxInventorySyncReconciler.reconcile_controllers(
               [controller("ctrl-1", "agent-a", "https://awx.example.com", "secret-a")],
               plugin_package: package,
               store: MemoryStore,
               grant_template: &grant_template/1,
               partition_resolver: &partition_for_agent/1
             )

    assert {:ok, stats} =
             AwxInventorySyncReconciler.reconcile_controllers([],
               plugin_package: package,
               store: MemoryStore,
               grant_template: &grant_template/1,
               partition_resolver: &partition_for_agent/1
             )

    assert stats.disabled == 1
    assert MemoryStore.records()["ansible:awx-inventory-sync:agent-a"].enabled == false
  end

  test "disabled controllers are excluded from the materialized assignment" do
    package = %{id: Ecto.UUID.generate(), version: "0.1.1"}

    controllers = [
      controller("ctrl-on", "agent-a", "https://awx-on.example.com", "secret-a"),
      controller("ctrl-off", "agent-a", "https://awx-off.example.com", "secret-b", enabled: false)
    ]

    assert {:ok, stats} =
             AwxInventorySyncReconciler.reconcile_controllers(controllers,
               plugin_package: package,
               store: MemoryStore,
               grant_template: &grant_template/1,
               partition_resolver: &partition_for_agent/1
             )

    assert stats.desired_assignments == 1
    agent_a = MemoryStore.records()["ansible:awx-inventory-sync:agent-a"]
    assert [only] = agent_a.params["controllers"]
    assert only["controller_id"] == "ctrl-on"
  end

  test "disabling an agent's last controller retracts its assignment" do
    package = %{id: Ecto.UUID.generate(), version: "0.1.1"}

    assert {:ok, _} =
             AwxInventorySyncReconciler.reconcile_controllers(
               [controller("ctrl-a", "agent-a", "https://awx-a.example.com", "secret-a")],
               plugin_package: package,
               store: MemoryStore,
               grant_template: &grant_template/1,
               partition_resolver: &partition_for_agent/1
             )

    assert MemoryStore.records()["ansible:awx-inventory-sync:agent-a"].enabled == true

    # Same controller, now disabled → an agent-scoped reconcile retracts.
    assert {:ok, stats} =
             AwxInventorySyncReconciler.reconcile_agent("agent-a",
               controllers: [
                 controller("ctrl-a", "agent-a", "https://awx-a.example.com", "secret-a",
                   enabled: false
                 )
               ],
               plugin_package: package,
               store: MemoryStore,
               grant_template: &grant_template/1,
               partition_resolver: &partition_for_agent/1
             )

    assert stats.disabled == 1
    assert MemoryStore.records()["ansible:awx-inventory-sync:agent-a"].enabled == false
  end

  test "reconcile_agent scopes retraction to its own agent (never disables other agents)" do
    package = %{id: Ecto.UUID.generate(), version: "0.1.1"}

    controllers = [
      controller("ctrl-a", "agent-a", "https://awx-a.example.com", "secret-a"),
      controller("ctrl-b", "agent-b", "https://awx-b.example.com", "secret-b")
    ]

    # Seed both agents' assignments.
    assert {:ok, _} =
             AwxInventorySyncReconciler.reconcile_controllers(controllers,
               plugin_package: package,
               store: MemoryStore,
               grant_template: &grant_template/1,
               partition_resolver: &partition_for_agent/1
             )

    assert MemoryStore.records()["ansible:awx-inventory-sync:agent-a"].enabled == true
    assert MemoryStore.records()["ansible:awx-inventory-sync:agent-b"].enabled == true

    # Reconciling ONLY agent-a must leave agent-b's assignment enabled — the
    # pre-fix bug fed a single-agent desired set into a policy-wide disable and
    # tore down every other agent.
    assert {:ok, stats} =
             AwxInventorySyncReconciler.reconcile_agent("agent-a",
               controllers: controllers,
               plugin_package: package,
               store: MemoryStore,
               grant_template: &grant_template/1,
               partition_resolver: &partition_for_agent/1
             )

    assert stats.disabled == 0
    assert MemoryStore.records()["ansible:awx-inventory-sync:agent-a"].enabled == true
    assert MemoryStore.records()["ansible:awx-inventory-sync:agent-b"].enabled == true
  end

  test "reconcile_agent disables only its OWN stale assignment when its controllers are gone" do
    package = %{id: Ecto.UUID.generate(), version: "0.1.1"}

    controllers = [
      controller("ctrl-a", "agent-a", "https://awx-a.example.com", "secret-a"),
      controller("ctrl-b", "agent-b", "https://awx-b.example.com", "secret-b")
    ]

    assert {:ok, _} =
             AwxInventorySyncReconciler.reconcile_controllers(controllers,
               plugin_package: package,
               store: MemoryStore,
               grant_template: &grant_template/1,
               partition_resolver: &partition_for_agent/1
             )

    # agent-a's controller removed. A per-agent reconcile for agent-a retracts
    # agent-a's now-stale assignment but must not touch agent-b's.
    assert {:ok, stats} =
             AwxInventorySyncReconciler.reconcile_agent("agent-a",
               controllers: [
                 controller("ctrl-b", "agent-b", "https://awx-b.example.com", "secret-b")
               ],
               plugin_package: package,
               store: MemoryStore,
               grant_template: &grant_template/1,
               partition_resolver: &partition_for_agent/1
             )

    assert stats.disabled == 1
    assert MemoryStore.records()["ansible:awx-inventory-sync:agent-a"].enabled == false
    assert MemoryStore.records()["ansible:awx-inventory-sync:agent-b"].enabled == true
  end

  defp controller(id, agent_id, base_url, secret_id, opts \\ []) do
    %{
      id: id,
      agent_id: agent_id,
      base_url: base_url,
      credential_secret_id: "legacy-#{secret_id}",
      sync_credential_secret_id: secret_id,
      name: Keyword.get(opts, :name, id),
      enabled: Keyword.get(opts, :enabled, true),
      inventory_sync_interval_seconds: Keyword.get(opts, :interval, 300),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp partition_for_agent(agent_id), do: {:ok, "test-partition:" <> agent_id}

  defp grant_template(controller) do
    {:ok, secret_id} = Controller.credential_secret_id_for(controller, :sync)
    {:ok, scope} = AwxClient.broker_scope(controller.base_url, "awx.inventory_sync", %{})
    secret_ref = SecretRefs.network_credential_ref(secret_id)

    {:ok,
     %{
       "schema" => "serviceradar.edge_credential_broker_grant.v1",
       "grant_type" => "awx_oauth2_token",
       "credential_secret_ref" => secret_ref,
       "consumer" => %{
         "kind" => "ansible",
         "id" => controller.id,
         "purpose" => "awx.inventory_sync"
       },
       "target" => %{
         "kind" => "awx_controller",
         "id" => controller.id,
         "agent_id" => controller.agent_id
       },
       "resolution_location" => "agent",
       "allow" => scope.allow,
       "ttl_seconds" => 300
     }}
  end
end
