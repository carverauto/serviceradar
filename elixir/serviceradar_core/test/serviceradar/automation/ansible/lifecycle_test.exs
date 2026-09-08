defmodule ServiceRadar.Automation.Ansible.LifecycleTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Automation.Ansible.Lifecycle

  defmodule Recorder do
    @moduledoc false

    def start_link do
      Agent.start_link(fn -> [] end, name: __MODULE__)
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

    def record(event), do: Agent.update(__MODULE__, &[event | &1])
    def events, do: Agent.get(__MODULE__, &Enum.reverse/1)
  end

  defmodule HealthWorker do
    @moduledoc false
    def ensure_scheduled(controller_id), do: Recorder.record({:health, controller_id})
  end

  defmodule CatalogWorker do
    @moduledoc false
    def ensure_scheduled(controller_id), do: Recorder.record({:catalog, controller_id})
  end

  defmodule PulseWorker do
    @moduledoc false
    def ensure_scheduled(controller_id), do: Recorder.record({:pulse, controller_id})
  end

  defmodule GlobalWorker do
    @moduledoc false
    def ensure_scheduled, do: Recorder.record(:global)
  end

  defmodule GitSyncWorker do
    @moduledoc false
    def ensure_scheduled(repository_id), do: Recorder.record({:git_sync, repository_id})
  end

  defmodule InventoryReconciler do
    @moduledoc false

    def reconcile_agent(agent_id, _opts) do
      Recorder.record({:reconcile_agent, agent_id})
      {:ok, %{desired_assignments: 1}}
    end

    def reconcile_all(_opts) do
      Recorder.record(:reconcile_all)
      {:ok, %{desired_assignments: 2}}
    end
  end

  setup do
    {:ok, _pid} = Recorder.start_link()
    on_exit(&Recorder.stop/0)
    :ok
  end

  test "seed_controller schedules controller workers, global workers, and assignment reconciliation" do
    assert :ok =
             Lifecycle.seed_controller(%{id: "ctrl-a", agent_id: "agent-a"},
               per_controller_workers: [HealthWorker, CatalogWorker, PulseWorker],
               global_workers: [GlobalWorker],
               inventory_reconciler: InventoryReconciler
             )

    assert Recorder.events() == [
             {:health, "ctrl-a"},
             {:catalog, "ctrl-a"},
             {:pulse, "ctrl-a"},
             :global,
             {:reconcile_agent, "agent-a"}
           ]
  end

  test "teardown_controller retracts the agent assignment WITHOUT re-scheduling controller workers" do
    assert :ok =
             Lifecycle.teardown_controller(%{id: "ctrl-a", agent_id: "agent-a"},
               per_controller_workers: [HealthWorker, CatalogWorker, PulseWorker],
               global_workers: [GlobalWorker],
               inventory_reconciler: InventoryReconciler
             )

    # Only the agent-scoped reconcile runs; no health/catalog/pulse/global
    # worker is (re)scheduled for a controller that is being removed.
    assert Recorder.events() == [{:reconcile_agent, "agent-a"}]
  end

  test "seed_all schedules every controller and reconciles all assignments" do
    assert :ok =
             Lifecycle.seed_all(
               controllers: [%{id: "ctrl-a"}, %{id: "ctrl-b"}],
               repositories: [],
               per_controller_workers: [HealthWorker],
               global_workers: [GlobalWorker],
               inventory_reconciler: InventoryReconciler
             )

    assert Recorder.events() == [
             {:health, "ctrl-a"},
             {:health, "ctrl-b"},
             :global,
             :reconcile_all
           ]
  end

  test "seed_all seeds the git catalog sync for every playbook repository" do
    # The GitCatalogSyncWorker only re-schedules itself from perform/1; this
    # backstop is what seeds job #1 for repositories that predate the
    # create/update hook (without it a repository stayed `pending` forever).
    assert :ok =
             Lifecycle.seed_all(
               controllers: [%{id: "ctrl-a"}],
               repositories: [%{id: "repo-a"}, %{"id" => "repo-b"}],
               per_controller_workers: [HealthWorker],
               global_workers: [GlobalWorker],
               inventory_reconciler: InventoryReconciler,
               git_catalog_sync_worker: GitSyncWorker
             )

    assert Recorder.events() == [
             {:health, "ctrl-a"},
             :global,
             :reconcile_all,
             {:git_sync, "repo-a"},
             {:git_sync, "repo-b"}
           ]
  end

  test "seed_all seeds repository syncs even with no controllers registered" do
    assert :ok =
             Lifecycle.seed_all(
               controllers: [],
               repositories: [%{id: "repo-a"}],
               per_controller_workers: [HealthWorker],
               global_workers: [GlobalWorker],
               inventory_reconciler: InventoryReconciler,
               git_catalog_sync_worker: GitSyncWorker
             )

    assert Recorder.events() == [:global, :reconcile_all, {:git_sync, "repo-a"}]
  end
end
