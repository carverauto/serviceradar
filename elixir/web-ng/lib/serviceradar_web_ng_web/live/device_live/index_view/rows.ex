defmodule ServiceRadarWebNGWeb.DeviceLive.IndexView.Rows do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  def effective_availability(row, effective_availability_by_device) when is_map(row) do
    uid = Map.get(row, "uid") || Map.get(row, "id")

    case Map.fetch(effective_availability_by_device, uid) do
      {:ok, value} -> value
      :error -> Map.get(row, "is_available")
    end
  end

  def effective_availability(_row, _effective_availability_by_device), do: nil

  def agent_device_row?(row, agent_device_uids) when is_map(row) do
    device_uid = Map.get(row, "uid") || Map.get(row, "id")
    is_binary(device_uid) and String.trim(device_uid) != "" and MapSet.member?(agent_device_uids, device_uid)
  end

  def agent_device_row?(_row, _agent_device_uids), do: false

  def has_filter?(srql, field, value) do
    query = Map.get(srql || %{}, :query, "") || ""
    String.contains?(query, "#{field}:#{value}")
  end

  def has_any_filter?(srql) do
    query = Map.get(srql || %{}, :query, "") || ""
    String.trim(query) != ""
  end

  def deleted_device_row?(row) when is_map(row) do
    value = Map.get(row, "deleted_at")
    not is_nil(value) and value != ""
  end

  def active_device_row?(row) when is_map(row) do
    row
    |> Map.get("is_active", true)
    |> normalize_bool(default: true)
  end

  def active_device_row?(_row), do: true

  defp normalize_bool(value, _opts) when is_boolean(value), do: value
  defp normalize_bool(1, _opts), do: true
  defp normalize_bool(0, _opts), do: false

  defp normalize_bool(value, opts) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "true" -> true
      "1" -> true
      "yes" -> true
      "active" -> true
      "in_service" -> true
      "false" -> false
      "0" -> false
      "no" -> false
      "inactive" -> false
      "out_of_service" -> false
      _ -> Keyword.get(opts, :default, false)
    end
  end

  defp normalize_bool(_value, opts), do: Keyword.get(opts, :default, false)
end
