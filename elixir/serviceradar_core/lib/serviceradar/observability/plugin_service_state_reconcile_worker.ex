defmodule ServiceRadar.Observability.PluginServiceStateReconcileWorker do
  @moduledoc """
  Reconciles plugin service state against plugin assignments on a schedule.

  `ServiceStateRegistry.reconcile_plugin_assignments/0` backfills the pending
  row of every enabled assignment that has none, re-ranks the winner among a
  plugin identity's gateway variants, and deactivates active plugin rows whose
  assignment is gone, disabled or no longer reports results.

  The web-ng assignment and package actions update service state as they
  change, but several core paths change assignments without doing so (policy
  and integration provisioning, owned-assignment retraction), and a release can
  change which assignments are eligible. This job converges those. It replaces
  the reconciliation the `/services` page used to run, with writes and a global
  advisory lock, on every view.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: 240, states: :incomplete]

  alias ServiceRadar.Observability.ServiceStateRegistry

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case ServiceStateRegistry.reconcile_plugin_assignments() do
      {:ok, count} ->
        Logger.debug("Reconciled plugin service state", count: count)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
