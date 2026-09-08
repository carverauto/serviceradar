defmodule ServiceRadarWebNGWeb.DeviceLive.NorthboundHistoryData do
  @moduledoc false

  alias ServiceRadar.Automation.Northbound.History, as: NorthboundHistory
  alias ServiceRadarWebNG.RBAC

  require Logger

  @history_limit 10

  def load(nil, _device_uid), do: {[], nil}
  def load(_scope, nil), do: {[], nil}

  def load(scope, device_uid) do
    if RBAC.can?(scope, "northbound.actions.view") do
      case NorthboundHistory.list_for_device(device_uid,
             scope: scope,
             limit: @history_limit,
             exclude_provider_types: [:ansible]
           ) do
        {:ok, history} ->
          {history, nil}

        {:error, reason} ->
          Logger.warning("Failed to load northbound device action history: #{inspect(reason)}")
          {[], "Failed to load action history."}
      end
    else
      {[], nil}
    end
  end
end
