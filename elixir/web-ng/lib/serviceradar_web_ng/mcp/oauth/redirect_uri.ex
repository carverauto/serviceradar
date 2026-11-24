defmodule ServiceRadarWebNG.Mcp.OAuth.RedirectURI do
  @moduledoc false

  @loopback_hosts MapSet.new(["127.0.0.1", "localhost", "[::1]", "::1"])
  @allowed_https_uris MapSet.new([
                        "https://antigravity.google/oauth-callback"
                      ])

  @spec allowed?(term()) :: boolean()
  def allowed?(uri) when is_binary(uri) do
    loopback?(uri) or allowlisted_https?(uri)
  end

  def allowed?(_), do: false

  @spec loopback?(term()) :: boolean()
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

  @spec allowlisted_https?(term()) :: boolean()
  def allowlisted_https?(uri) when is_binary(uri) do
    valid_exact_https_uri?(uri) and MapSet.member?(@allowed_https_uris, uri)
  end

  def allowlisted_https?(_), do: false

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

  defp valid_exact_https_uri?(uri) when is_binary(uri) do
    if uri == "" or String.contains?(uri, ["\\", "..", "\r", "\n", "\0"]) do
      false
    else
      case URI.new(uri) do
        {:ok, %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil, path: path} = parsed}
        when is_binary(host) and host != "" ->
          valid_port?(parsed.port) and is_binary(path) and String.starts_with?(path, "/")

        _ ->
          false
      end
    end
  end

  defp valid_exact_https_uri?(_), do: false

  defp reject_blank(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) or v == "" end)
  end

  defp valid_port?(nil), do: true
  defp valid_port?(port) when is_integer(port) and port > 0 and port <= 65_535, do: true
  defp valid_port?(_), do: false
end
