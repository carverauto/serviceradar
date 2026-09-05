defmodule ServiceRadar.Monitoring.AlertNotifier do
  @moduledoc """
  Publishes an `{:alert_created, %{id: id}}` event for every newly raised alert.

  `ServiceRadar.Monitoring.Alert` exposes exactly one create action
  (`:trigger`), so notifying here covers every writer - `AlertGenerator` (and
  through it `StatefulAlertEngine.AlertLifecycle`, log promotion and trivy
  reports), the camera alert router and any future direct creator - without
  each of them having to remember to broadcast.

  The pulse is a LiveView refresh trigger only, like the other `*_pubsub`
  broadcasters: it originates no incident notification. Design D8 still
  reserves originating a new incident notification for `AlertLifecycle`.
  """

  use Ash.Notifier

  alias Ash.Notifier.Notification
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Observability.AlertPubSub

  @impl Ash.Notifier
  def notify(%Notification{resource: Alert, action: %{type: :create}, data: %{id: id}}) do
    AlertPubSub.broadcast_alert_created(%{id: id})
    :ok
  end

  def notify(_notification), do: :ok
end
