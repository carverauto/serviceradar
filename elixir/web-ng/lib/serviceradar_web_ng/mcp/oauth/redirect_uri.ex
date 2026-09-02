defmodule ServiceRadarWebNG.Mcp.OAuth.RedirectURI do
  @moduledoc false

  @loopback_hosts MapSet.new(["127.0.0.1", "localhost", "[::1]", "::1"])

  @spec loopback?(String.t()) :: boolean()
  def loopback?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: "http", host: host, userinfo: nil} = parsed
      when is_binary(host) ->
        MapSet.member?(@loopback_hosts, String.downcase(host)) and valid_port?(parsed.port)

      _ ->
        false
    end
  end

  def loopback?(_), do: false

  @spec append_query(String.t(), map()) :: String.t()
  def append_query(uri, extras) when is_binary(uri) and is_map(extras) do
    parsed = URI.parse(uri)

    query =
      (parsed.query || "")
      |> URI.decode_query()
      |> Map.merge(reject_blank(extras))
      |> URI.encode_query()

    URI.to_string(%{parsed | query: query})
  end

  defp reject_blank(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) or v == "" end)
  end

  defp valid_port?(nil), do: true
  defp valid_port?(port) when is_integer(port) and port > 0 and port <= 65_535, do: true
  defp valid_port?(_), do: false
end
