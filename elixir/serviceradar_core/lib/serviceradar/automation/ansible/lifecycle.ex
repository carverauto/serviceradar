defmodule ServiceRadar.Automation.Ansible.Lifecycle do
  @moduledoc """
  Best-effort lifecycle seeding for AWX/AAP controllers.

  Controller resource writes should converge the operational jobs that make the
  integration live: health checks, catalog sync, run pulse/watchdog, retention,
  and the inventory-sync plugin assignment.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.AwxCatalogSyncWorker
  alias ServiceRadar.Automation.Ansible.AwxInventorySyncReconciler
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.ControllerHealthWorker
  alias ServiceRadar.Automation.Ansible.GitCatalogSyncWorker
  alias ServiceRadar.Automation.Ansible.PlaybookRepository
  alias ServiceRadar.Automation.Ansible.RetentionWorker
  alias ServiceRadar.Automation.Ansible.RunPulseWorker
  alias ServiceRadar.Automation.Ansible.RunWatchdog
  alias ServiceRadar.Automation.Ansible.ScheduleEvaluatorWorker

  require Ash.Query
  require Logger

  @per_controller_workers [ControllerHealthWorker, AwxCatalogSyncWorker, RunPulseWorker]
  @global_workers [ScheduleEvaluatorWorker, RunWatchdog, RetentionWorker]

  @spec seed_controller(map(), keyword()) :: :ok
  def seed_controller(controller, opts \\ []) do
    controller_id = string_value(controller, :id)
    agent_id = string_value(controller, :agent_id)

    if controller_id do
      opts
      |> per_controller_workers()
      |> Enum.each(&ensure_scheduled(&1, [controller_id]))
    end

    ensure_global_workers(opts)

    if agent_id, do: safe_reconcile_agent(agent_id, opts)

    :ok
  end

  @doc """
  Tear down a removed controller: retract its contribution to its agent's
  inventory-sync assignment (rebuilt without it, or disabled if it was the
  agent's last controller). Unlike `seed_controller/2`, this does NOT re-ensure
  the per-controller jobs — the controller is gone, and its self-scheduling
  workers terminate on their next tick when the controller can no longer be
  read.
  """
  @spec teardown_controller(map(), keyword()) :: :ok
  def teardown_controller(controller, opts \\ []) do
    case string_value(controller, :agent_id) do
      nil -> :ok
      agent_id -> safe_reconcile_agent(agent_id, opts)
    end

    :ok
  end

  # Seeding runs inside the controller-write transaction (an Ash after_action
  # hook). It must never raise: a raised error would roll back the controller
  # write itself. Any reconcile failure is logged and left to the boot/backstop
  # reconcile to heal.
  defp safe_reconcile_agent(agent_id, opts) do
    case inventory_reconciler(opts).reconcile_agent(agent_id, opts) do
      {:ok, _summary} ->
        :ok

      {:error, reason} ->
        Logger.debug("AWX inventory sync reconciliation deferred",
          agent_id: agent_id,
          reason: inspect(reason)
        )
    end
  rescue
    error ->
      Logger.warning("AWX inventory sync reconciliation raised; deferred to backstop",
        agent_id: agent_id,
        reason: Exception.message(error)
      )

      :ok
  end

  @spec seed_all(keyword()) :: :ok
  def seed_all(opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:awx_lifecycle_seed))

    case load_controllers(actor, opts) do
      {:ok, controllers} ->
        Enum.each(controllers, fn controller ->
          if controller_id = string_value(controller, :id) do
            opts
            |> per_controller_workers()
            |> Enum.each(&ensure_scheduled(&1, [controller_id]))
          end
        end)

        ensure_global_workers(opts)

        case inventory_reconciler(opts).reconcile_all(Keyword.put(opts, :actor, actor)) do
          {:ok, _summary} ->
            :ok

          {:error, reason} ->
            Logger.debug("AWX inventory sync reconciliation deferred", reason: inspect(reason))
        end

      {:error, reason} ->
        Logger.debug("AWX lifecycle seed skipped; controllers unavailable",
          reason: inspect(reason)
        )
    end

    # Playbook repositories are independent of controllers: git catalog sync
    # must run even when no AWX/AAP controller is registered. This is also the
    # backstop that seeds the FIRST GitCatalogSyncWorker job for repositories
    # created before the create/update hook existed (the worker only
    # self-reschedules from perform/1, so without a seed job a repository
    # stayed `pending` forever).
    ensure_repository_syncs(actor, opts)

    :ok
  end

  defp ensure_repository_syncs(actor, opts) do
    case load_repositories(actor, opts) do
      {:ok, repositories} ->
        Enum.each(repositories, fn repository ->
          if repository_id = string_value(repository, :id) do
            ensure_scheduled(git_catalog_sync_worker(opts), [repository_id])
          end
        end)

      {:error, reason} ->
        Logger.debug("AWX lifecycle seed skipped repository syncs; repositories unavailable",
          reason: inspect(reason)
        )
    end
  end

  defp load_repositories(actor, opts) do
    case Keyword.fetch(opts, :repositories) do
      {:ok, repositories} ->
        {:ok, repositories}

      :error ->
        PlaybookRepository
        |> Ash.Query.for_read(:read, %{}, actor: actor)
        |> Ash.read(actor: actor)
    end
  end

  defp load_controllers(actor, opts) do
    case Keyword.fetch(opts, :controllers) do
      {:ok, controllers} ->
        {:ok, controllers}

      :error ->
        Controller
        |> Ash.Query.for_read(:read, %{}, actor: actor)
        |> Ash.Query.filter(enabled == true)
        |> Ash.read(actor: actor)
    end
  end

  defp ensure_global_workers(opts) do
    opts
    |> global_workers()
    |> Enum.each(&ensure_scheduled(&1, []))
  end

  defp per_controller_workers(opts),
    do: Keyword.get(opts, :per_controller_workers, @per_controller_workers)

  defp global_workers(opts), do: Keyword.get(opts, :global_workers, @global_workers)

  defp git_catalog_sync_worker(opts),
    do: Keyword.get(opts, :git_catalog_sync_worker, GitCatalogSyncWorker)

  defp inventory_reconciler(opts),
    do: Keyword.get(opts, :inventory_reconciler, AwxInventorySyncReconciler)

  defp ensure_scheduled(worker, args) do
    result = apply(worker, :ensure_scheduled, args)

    case result do
      {:ok, _} ->
        :ok

      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug("AWX lifecycle scheduling deferred",
          worker: inspect(worker),
          reason: inspect(reason)
        )
    end
  rescue
    error ->
      Logger.debug("AWX lifecycle scheduling failed",
        worker: inspect(worker),
        reason: Exception.message(error)
      )
  end

  defp string_value(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      nil ->
        nil

      value ->
        to_string(value)
    end
  end
end
