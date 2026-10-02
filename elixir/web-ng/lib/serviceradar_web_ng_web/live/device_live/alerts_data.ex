defmodule ServiceRadarWebNGWeb.DeviceLive.AlertsData do
  @moduledoc false

  alias ServiceRadar.Monitoring.Alert

  require Ash.Query
  require Logger

  @limit 50

  def load_alerts(device_uid, scope) do
    query =
      Alert
      |> Ash.Query.for_read(:by_device, %{device_uid: device_uid}, scope: scope)
      |> Ash.Query.sort(triggered_at: :desc)
      |> Ash.Query.limit(@limit)

    case Ash.read(query, scope: scope, domain: ServiceRadar.Monitoring) do
      {:ok, alerts} ->
        {:ok, alerts}

      {:error, reason} ->
        Logger.warning("Device alerts load failed for #{device_uid}: #{inspect(reason)}")
        {:error, "Failed to load alerts"}
    end
  end
end
