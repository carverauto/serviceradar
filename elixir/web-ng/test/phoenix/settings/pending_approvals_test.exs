defmodule ServiceRadarWebNGWeb.Settings.PendingApprovalsTest do
  @moduledoc """
  Exercises the real query behind the settings nav badge.

  The value here is that it runs `Ash.count/2` against a real repo. The module
  compiles either way, so nothing but execution proves the query is well-formed
  and that `scope:` is accepted -- and a badly-formed one would surface as a
  crashed navigation render on every settings page, not merely a missing badge.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: true

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.Settings.PendingApprovals

  defp viewer_scope, do: %Scope{permissions: MapSet.new(["plugins.view"])}

  test "counts run against the repo and return a map" do
    counts = PendingApprovals.counts(viewer_scope())

    assert is_map(counts)

    # Every value present must be a positive integer: zeros are dropped so a
    # caller can treat an empty map as "nothing pending" without checking for 0.
    assert Enum.all?(counts, fn {view, count} ->
             view in [:addons, :plugins] and is_integer(count) and count > 0
           end)
  end

  test "a scope that cannot read packages reports nothing rather than crashing" do
    # A nav badge is not a place to surface an authorization error. The counts
    # fall back to zero, and zeros are dropped, so the nav renders unchanged.
    assert PendingApprovals.counts(%Scope{permissions: MapSet.new([])}) == %{}
  end

  test "a nil scope is tolerated" do
    # `settings_nav_tree` is assigned before `current_scope` is guaranteed to be
    # present on every mount path, so nil has to be survivable.
    assert PendingApprovals.counts(nil) == %{}
  end
end
