defmodule ServiceRadar.Observability.WarehouseRetentionNotifier do
  @moduledoc """
  Tells core's retention applier that an operator changed a dataset, and audits the change.

  The broadcast goes over the clustered `ServiceRadar.PubSub`, so a save in web-ng
  reaches the applier in core without a restart. The applier also reconciles on a
  timer, so a lost broadcast delays the apply rather than losing it.
  """

  use Ash.Notifier

  alias ServiceRadar.Events.AuditNotifier
  alias ServiceRadar.Observability.WarehouseRetentionSetting

  require Logger

  @topic "warehouse_retention"

  @doc "The PubSub topic the applier subscribes to."
  @spec topic() :: String.t()
  def topic, do: @topic

  @impl Ash.Notifier
  def notify(
        %Ash.Notifier.Notification{
          resource: WarehouseRetentionSetting,
          action: %{name: action_name},
          data: record
        } =
          notification
      )
      when action_name in [:create, :set_days] do
    broadcast(record.dataset)

    AuditNotifier.write_async(notification,
      resource_type: "warehouse_retention_setting",
      resource_id: record.dataset,
      resource_name: record.dataset,
      details: %{dataset: record.dataset, days: record.days}
    )

    :ok
  end

  def notify(_notification), do: :ok

  @doc false
  @spec broadcast(String.t()) :: :ok
  def broadcast(dataset) do
    Phoenix.PubSub.broadcast(ServiceRadar.PubSub, @topic, {:warehouse_retention_changed, dataset})
    :ok
  rescue
    # PubSub is not running (a script or a test without the application); the
    # applier's timer still picks the change up.
    error ->
      Logger.debug("warehouse retention change not broadcast: #{Exception.message(error)}")
      :ok
  end
end
