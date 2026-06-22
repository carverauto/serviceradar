defmodule ServiceRadarWebNGWeb.DeviceLive.IndexData.Availability do
  @moduledoc false

  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadarWebNGWeb.DeviceLive.DeviceStateData

  require Ash.Query
  require Logger

  @agent_availability_fresh_seconds 2 * 60 * 60

  def agent_device_uids(devices, _scope) do
    devices
    |> Enum.filter(&is_map/1)
    |> Enum.map(&(Map.get(&1, "uid") || Map.get(&1, "id")))
    |> DeviceStateData.agent_device_uids()
  end

  def availability_source_agent_options(scope) do
    Agent
    |> Ash.Query.for_read(:read, %{}, scope: scope)
    |> Ash.Query.sort(uid: :asc)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, %{results: agents}} -> agents
      {:ok, agents} when is_list(agents) -> agents
      _ -> []
    end
    |> Enum.map(fn agent ->
      display = agent.name || agent.host || agent.uid
      {"#{display} (#{agent.uid})", agent.uid}
    end)
  rescue
    reason ->
      Logger.warning("Failed to load availability source agents: #{inspect(reason)}")
      []
  end

  def effective_availability(devices, scope) do
    device_uids =
      devices
      |> Enum.filter(&is_map/1)
      |> Enum.map(&(Map.get(&1, "uid") || Map.get(&1, "id")))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if device_uids == [] do
      %{}
    else
      rows =
        DeviceAgentAvailability
        |> Ash.Query.for_read(:read, %{}, scope: scope)
        |> Ash.Query.filter(device_uid in ^device_uids)
        |> Ash.Query.sort(checked_at: :desc, agent_id: :asc)
        |> Ash.read!(scope: scope)

      rows_by_device = Enum.group_by(rows, & &1.device_uid)

      devices
      |> Enum.filter(&is_map/1)
      |> Enum.reduce(%{}, fn device, acc ->
        uid = Map.get(device, "uid") || Map.get(device, "id")
        availability_rows = Map.get(rows_by_device, uid, [])

        case effective_availability_from_rows(device, availability_rows) do
          nil -> acc
          value -> Map.put(acc, uid, value)
        end
      end)
    end
  rescue
    reason ->
      Logger.warning("Failed to load effective device availability: #{inspect(reason)}")
      %{}
  end

  defp effective_availability_from_rows(_device, []), do: nil

  defp effective_availability_from_rows(device, rows) do
    fresh_rows = Enum.filter(rows, &agent_availability_fresh?/1)

    if fresh_rows == [] do
      nil
    else
      effective_availability_from_fresh_rows(device, fresh_rows)
    end
  end

  defp effective_availability_from_fresh_rows(device, rows) do
    source_agent_id =
      device
      |> Map.get("availability_source_agent_id")
      |> blank_to_nil()

    if is_binary(source_agent_id) do
      rows
      |> Enum.find(&(&1.agent_id == source_agent_id))
      |> case do
        nil -> nil
        row -> row.is_available == true
      end
    else
      Enum.any?(rows, &(&1.is_available == true))
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp agent_availability_fresh?(row) do
    cutoff = DateTime.add(DateTime.utc_now(), -@agent_availability_fresh_seconds, :second)

    case Map.get(row, :checked_at) do
      %DateTime{} = observed_at -> DateTime.after?(observed_at, cutoff)
      _ -> false
    end
  end
end
