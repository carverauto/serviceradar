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

  defp staged_count(resource, scope) do
    resource
    |> Ash.Query.filter(status == :staged)
    |> Ash.count(scope: scope)
    |> case do
      {:ok, count} when is_integer(count) -> count
      _ -> 0
    end
  end
end
