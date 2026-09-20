defmodule ServiceRadar.NetworkConfig.Downparser do
  @moduledoc """
  Facade over the V1 network-config downparser NIF.

  Parsing happens in core, not inside a Wasm plugin. Fixtures must be
  invented IOS-like text.
  """

  alias ServiceRadar.NetworkConfig.Native

  @parser_version "network_config_v1"

  @spec parser_version() :: String.t()
  def parser_version, do: @parser_version

  @spec parse(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def parse(body) when is_binary(body) do
    case Native.parse_running_config(body) do
      {:ok, facts} when is_list(facts) -> {:ok, Enum.map(facts, &normalize_fact/1)}
      facts when is_list(facts) -> {:ok, Enum.map(facts, &normalize_fact/1)}
      {:error, reason} -> {:error, reason}
      other -> {:error, "unexpected downparser result: #{inspect(other)}"}
    end
  rescue
    error ->
      message = Exception.message(error)

      if String.contains?(message, "nif") do
        {:error, "network config nif is not loaded"}
      else
        {:error, message}
      end
  end

  defp normalize_fact(fact) when is_map(fact) do
    %{
      if_name: Map.get(fact, :if_name) || Map.get(fact, "if_name"),
      ipv4_prefix: Map.get(fact, :ipv4_prefix) || Map.get(fact, "ipv4_prefix"),
      ipv6_prefix: Map.get(fact, :ipv6_prefix) || Map.get(fact, "ipv6_prefix"),
      vlan: Map.get(fact, :vlan) || Map.get(fact, "vlan"),
      description: Map.get(fact, :description) || Map.get(fact, "description"),
      shutdown: Map.get(fact, :shutdown) || Map.get(fact, "shutdown") || false,
      vrf: Map.get(fact, :vrf) || Map.get(fact, "vrf")
    }
  end
end
