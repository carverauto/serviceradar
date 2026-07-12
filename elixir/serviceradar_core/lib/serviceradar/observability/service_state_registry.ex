defmodule ServiceRadar.Observability.ServiceStateRegistry do
  @moduledoc """
  Maintains the current service state registry.

  This module is the public facade for status ingestion, plugin state repair, and
  assignment lifecycle handling. Persistence and reconciliation details live in
  the modules under `ServiceStateRegistry`.
  """

  alias ServiceRadar.Observability.ServiceStateRegistry.AssignmentLifecycle
  alias ServiceRadar.Observability.ServiceStateRegistry.HistoryRepair
  alias ServiceRadar.Observability.ServiceStateRegistry.PluginState
  alias ServiceRadar.Observability.ServiceStateRegistry.SideEffects
  alias ServiceRadar.Observability.ServiceStateRegistry.StatusIngestor
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage

  @doc false
  @spec acquire_plugin_state_lock(map()) :: :ok | {:error, term()}
  defdelegate acquire_plugin_state_lock(identity), to: PluginState, as: :acquire_lock

  @spec upsert_from_status(map()) :: :ok
  defdelegate upsert_from_status(status), to: StatusIngestor, as: :upsert

  @doc """
  Persists a current service state while returning database or side-effect errors.

  The physical `ServiceState` upsert is timestamp-guarded. Plugin rows are then
  reconciled across gateway variants: real results outrank assignment placeholders,
  newer observations win, and unavailable wins an equal-timestamp tie. Repair may
  reactivate an inactive exact row when its timestamp and availability are unchanged.
  """
  @spec upsert_from_status_strict(map()) :: :ok | {:error, term()}
  defdelegate upsert_from_status_strict(status), to: StatusIngestor, as: :upsert_strict

  @doc false
  @spec upsert_from_status_strict_with_notifications(map()) ::
          {:ok, list(), list()} | {:error, term()}
  defdelegate upsert_from_status_strict_with_notifications(status),
    to: StatusIngestor,
    as: :upsert_strict_with_notifications

  @doc false
  @spec replace_from_status_with_notifications(map()) ::
          {:ok, list(), list()} | {:error, term()}
  def replace_from_status_with_notifications(status) do
    StatusIngestor.replace_with_notifications(status, preserve_gateway?: true)
  end

  @doc false
  @spec dispatch_deferred_side_effects(list()) :: :ok | {:error, term()}
  defdelegate dispatch_deferred_side_effects(side_effects), to: SideEffects, as: :dispatch

  @doc """
  Batched equivalent of `upsert_from_status/1` for a list of statuses.

  Plugin statuses use the strict single-status path so assignment eligibility,
  logical-identity locks, and winner reconciliation remain transactional. Other
  statuses are deduplicated by `:unique_service_identity` and use
  `Ash.bulk_create(:upsert, ...)`.

  Returns `:ok`; failures are logged and never raise (matches the per-status
  path's best-effort contract on the ResultsRouter hot path).
  """
  @spec bulk_upsert_from_statuses([map()]) :: :ok
  defdelegate bulk_upsert_from_statuses(statuses), to: StatusIngestor, as: :bulk_upsert

  @spec repair_plugin_states_from_history(keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def repair_plugin_states_from_history(opts \\ []), do: HistoryRepair.repair(opts)

  @spec upsert_for_assignment(PluginAssignment.t()) :: :ok
  defdelegate upsert_for_assignment(assignment), to: AssignmentLifecycle, as: :upsert

  @spec reconcile_plugin_assignments(keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def reconcile_plugin_assignments(opts \\ []), do: AssignmentLifecycle.reconcile(opts)

  @spec deactivate_for_assignment(PluginAssignment.t()) :: :ok
  defdelegate deactivate_for_assignment(assignment),
    to: AssignmentLifecycle,
    as: :deactivate_assignment

  @spec deactivate_for_package(PluginPackage.t()) :: :ok
  defdelegate deactivate_for_package(package), to: AssignmentLifecycle, as: :deactivate_package
end
