defmodule ServiceRadarWebNGWeb.DeviceLive.EventsData do
  @moduledoc false

  require Logger

  @limit 50

  def load_events(srql_module, device_uid, scope) do
    query = "in:events device_uid:#{device_uid} sort:time:desc"
    opts = %{scope: scope, limit: @limit}

    case srql_module.query(query, opts) do
      {:ok, %{"results" => results}} when is_list(results) ->
        {:ok, Enum.filter(results, &is_map/1)}

      {:ok, %{"error" => error}} when is_binary(error) ->
        {:error, error}

      {:ok, _other} ->
        {:ok, []}

      {:error, reason} ->
        Logger.warning("Device events load failed for #{device_uid}: #{inspect(reason)}")
        {:error, "Failed to load events"}
    end
  end
end
