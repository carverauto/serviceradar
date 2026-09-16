defmodule ServiceRadar.Analytics.StarRocks.QueryCache do
  @moduledoc """
  Scoped StarRocks SRQL cache keys.

  Keys include authorization scope/version, backend generation, the full
  query, resolved time bounds and timezone. Tenant isolation and revoked
  access therefore cannot reuse another actor's entry.
  """

  @spec key(map()) :: String.t()
  def key(attrs) when is_map(attrs) do
    material = [
      Map.get(attrs, :tenant_id) || Map.get(attrs, "tenant_id"),
      Map.get(attrs, :actor_id) || Map.get(attrs, "actor_id"),
      Map.get(attrs, :authorization_scope) || Map.get(attrs, "authorization_scope"),
      Map.get(attrs, :authorization_version) || Map.get(attrs, "authorization_version"),
      Map.get(attrs, :backend_generation) || Map.get(attrs, "backend_generation"),
      Map.get(attrs, :query) || Map.get(attrs, "query"),
      encode_bounds(Map.get(attrs, :bounds) || Map.get(attrs, "bounds")),
      Map.get(attrs, :timezone) || Map.get(attrs, "timezone") || "Etc/UTC"
    ]

    :sha256
    |> :crypto.hash(Enum.map_join(material, "|", &to_string/1))
    |> Base.encode16(case: :lower)
  end

  defp encode_bounds(%{start: start_at, end: end_at}), do: "#{start_at}/#{end_at}"
  defp encode_bounds(%{"start" => start_at, "end" => end_at}), do: "#{start_at}/#{end_at}"
  defp encode_bounds(nil), do: ""
  defp encode_bounds(other), do: inspect(other)
end
