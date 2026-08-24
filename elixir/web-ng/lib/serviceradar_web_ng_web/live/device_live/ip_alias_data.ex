defmodule ServiceRadarWebNGWeb.DeviceLive.IpAliasData do
  @moduledoc false

  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadarWebNGWeb.DeviceLive.QueryData

  require Ash.Query

  # Above the writer's per-device interface cap (64), so a normal device is never
  # truncated here while a pathological one still cannot render unbounded.
  @max_displayed_aliases 200

  def load(_scope, nil, _show_stale), do: {[], nil}
  def load(nil, _device_uid, _show_stale), do: {[], "Scope unavailable"}

  def load(scope, device_uid, show_stale) do
    query =
      DeviceAliasState
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      # Both types are shown, and the table labels which is which. `:ip` is the
      # identity type -- what DIRE merges devices on. `:interface_ip` records an
      # address observed on the device's own interface WITHOUT making it a merge
      # key, because interface tables carry addresses several devices legitimately
      # share (VRRP/HSRP virtual IPs, EVPN anycast gateways, Junos internals).
      #
      # Showing them without distinguishing them would be worse than hiding them:
      # an operator reading "this device has 10.0.0.4" should be able to tell
      # whether that is an identity claim or just an observation.
      |> Ash.Query.filter(device_id == ^device_uid and alias_type in [:ip, :interface_ip])
      |> maybe_filter_states(show_stale)
      # Identity aliases first, then interface addresses; alphabetical within each.
      |> Ash.Query.sort(alias_type: :asc, alias_value: :asc)
      # The table is rendered un-streamed, so this is the only thing between a
      # many-addressed device and a very large DOM. The writer caps interface
      # addresses at 64 per device, so this bound is reached only by a device
      # that ALSO carries an unusual number of identity aliases -- a situation
      # worth truncating rather than rendering. Identity sorts first, so a
      # truncation drops interface observations before identity aliases.
      |> Ash.Query.limit(@max_displayed_aliases)

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
