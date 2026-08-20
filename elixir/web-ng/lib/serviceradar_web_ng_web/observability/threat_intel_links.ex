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

  @spec settings_path() :: String.t()
  def settings_path, do: "/settings/networks/threat-intel"

  defp escape_srql_value(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end
end
