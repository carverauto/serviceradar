defmodule ServiceRadar.DeclarativeChecks.ScheduleNotifier do
  @moduledoc """
  Keeps a declarative check's periodic `CoreEvaluationWorker` schedule,
  `StatefulAlertRule`, and `ServiceState` projections synchronized with its
  lifecycle (`1.1`, `1.3`, `2.4`).

  Matches plain maps rather than `%DeclarativeCheck{}` so there is zero
  compile-time dependency cycle between `DeclarativeCheck`, `ScheduleNotifier`,
  and `CoreEvaluationWorker`.
  """

  use Ash.Notifier

  alias Ash.Notifier.Notification
  alias ServiceRadar.DeclarativeChecks.AlertRuleSync
  alias ServiceRadar.DeclarativeChecks.CoreEvaluationWorker
  alias ServiceRadar.DeclarativeChecks.ServiceStateProjector

  require Logger

  @impl Ash.Notifier
  def notify(%Notification{action: %{name: :record_pass}}), do: :ok

  def notify(%Notification{action: %{type: :destroy}, data: %{id: id, slug: slug}}) do
    CoreEvaluationWorker.cancel(id)
    AlertRuleSync.delete_for_slug(slug)
    ServiceStateProjector.deactivate_all_for_slug(slug)
    :ok
  end

  def notify(%Notification{data: %{state: :enabled, id: id} = check}) do
    _ = AlertRuleSync.reconcile(check)

    case CoreEvaluationWorker.ensure_scheduled(check) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.debug("declarative check schedule deferred",
          check_id: id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  def notify(%Notification{data: %{id: id, slug: slug} = check}) do
    CoreEvaluationWorker.cancel(id)
    _ = AlertRuleSync.reconcile(check)
    ServiceStateProjector.deactivate_all_for_slug(slug)
    :ok
  end

  def notify(_notification), do: :ok
end
