defmodule ServiceRadarWebNGWeb.Observability.ThreatIntelLinks do
  @moduledoc false

  @spec device_path(term(), term()) :: String.t()
  def device_path(ip, device_uid \\ nil)

  def device_path(_ip, device_uid) when is_binary(device_uid) and device_uid != "" do
    "/devices/" <> URI.encode(device_uid, &URI.char_unreserved?/1)
  end

  def device_path(ip, _device_uid) do
    "/devices?" <> URI.encode_query(%{"q" => ~s(in:devices ip:"#{escape_srql_value(ip)}")})
  end

  @spec netflow_path(term()) :: String.t()
  def netflow_path(ip) do
    "/observability/netflows?" <>
      URI.encode_query(%{"view" => "explorer", "q" => ~s(in:netflows ip:"#{escape_srql_value(ip)}")})
  end

  @spec investigation_path(keyword()) :: String.t()
  def investigation_path(params \\ []) do
    query =
      params
      |> Enum.filter(fn {_key, value} -> present?(value) end)
      |> Map.new(fn {key, value} -> {to_string(key), to_string(value)} end)

    if query == %{} do
      "/security/threat-intel"
    else
      "/security/threat-intel?" <> URI.encode_query(query)
    end
  end

  @spec settings_path() :: String.t()
  def settings_path, do: "/settings/networks/threat-intel"

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_integer(value), do: true
  defp present?(value) when is_boolean(value), do: true
  defp present?(_), do: false

  defp escape_srql_value(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end
end
