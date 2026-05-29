defmodule ServiceRadarWebNGWeb.DeviceLive.IpAliasData do
  @moduledoc false

  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadarWebNGWeb.DeviceLive.QueryData

  require Ash.Query

  def load(_scope, nil, _show_stale), do: {[], nil}
  def load(nil, _device_uid, _show_stale), do: {[], "Scope unavailable"}

  def load(scope, device_uid, show_stale) do
    query =
      DeviceAliasState
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> Ash.Query.filter(device_id == ^device_uid and alias_type == :ip)
      |> maybe_filter_states(show_stale)
      |> Ash.Query.sort(alias_value: :asc)

    case Ash.read(query, scope: scope) do
      {:ok, aliases} -> {aliases, nil}
      {:error, reason} -> {[], QueryData.format_error(reason)}
    end
  end

  defp maybe_filter_states(query, true), do: query

  defp maybe_filter_states(query, false) do
    Ash.Query.filter(query, state in [:detected, :confirmed, :updated])
  end
end
