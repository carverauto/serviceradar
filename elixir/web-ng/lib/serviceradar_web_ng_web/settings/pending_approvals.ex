defmodule ServiceRadarWebNGWeb.Settings.PendingApprovals do
  @moduledoc """
  Counts packages sitting in `:staged` — imported, verified, and waiting for an
  operator to approve them.

  A staged package is inert. It ships no binary to an agent, publishes no
  credential descriptor, and reconciles nothing. That is the correct default for
  something newly imported, but it is indistinguishable from "working" until
  someone goes looking: the add-on and plugin pages already render a `staged`
  badge per row, so the information was never hidden, only undiscoverable. On
  demo twelve add-on packages had been staged for as long as seven weeks, and
  the first anyone noticed was when a feature that needed one did not work.

  The counts decorate the settings nav badge, which is why they are cheap and
  approximate by design: a `count` per resource, no rows loaded, and a failure
  is reported as "nothing pending" rather than crashing a navigation render.
  Falling back to zero is deliberate -- a nav badge is not a place to surface a
  database error, and the pages themselves remain the authority.
  """

  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.PluginPackage

  require Ash.Query

  @doc """
  Pending-approval counts, keyed by the settings view they belong to.

  Returns `%{}` when nothing is pending, so a caller can pattern-match on empty
  rather than checking for zeros.
  """
  @spec counts(term()) :: %{atom() => pos_integer()}
  def counts(scope) do
    %{
      addons: staged_count(AddonPackage, scope),
      plugins: staged_count(PluginPackage, scope)
    }
    |> Enum.reject(fn {_view, count} -> count == 0 end)
    |> Map.new()
  end

  defp staged_count(_resource, nil), do: 0

  defp staged_count(resource, scope) when is_map(scope) do
    if can_view_packages?(scope) do
      resource
      |> Ash.Query.filter(status == :staged)
      |> Ash.count(scope: scope)
      |> case do
        {:ok, count} when is_integer(count) -> count
        _ -> 0
      end
    else
      0
    end
  end

  defp staged_count(_resource, _scope), do: 0

  defp can_view_packages?(%{permissions: %MapSet{} = perms}),
    do: MapSet.member?(perms, "plugins.view") or MapSet.member?(perms, "settings.plugins.manage")

  defp can_view_packages?(%{user: user}) when not is_nil(user),
    do: RBAC.has_permission?(user, "plugins.view") or RBAC.has_permission?(user, "settings.plugins.manage")

  defp can_view_packages?(_), do: false
end
