defmodule ServiceRadarWebNG.RuntimeLimits do
  @moduledoc """
  Deployment-supplied runtime limits for advisory and enforcement hooks.
  """

  @managed_device_limit_key :managed_device_limit

  @spec managed_device_limit() :: pos_integer() | nil
  def managed_device_limit do
    :serviceradar_web_ng
    |> Application.get_env(@managed_device_limit_key)
    |> normalize_limit()
  end

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: limit

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_limit(_), do: nil
end
