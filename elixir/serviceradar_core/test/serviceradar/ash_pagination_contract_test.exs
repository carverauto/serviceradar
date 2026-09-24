defmodule ServiceRadar.AshPaginationContractTest do
  @moduledoc """
  Cross-resource invariant: a read action may never declare a `default_limit`
  larger than the page size it is actually able to return.

  Ash defaults `max_page_size` to 250 when an action does not declare one
  (`Ash.Resource.Actions.Read`), and clamps a requested page down to it with a
  bare `Enum.min/1` -- no error, no log. Declaring a larger `default_limit` is
  therefore not merely optimistic, it is unreachable: the action advertises a
  page it can never produce.

  What makes that dangerous rather than untidy is how Ash then reports the
  clamped page. `more?` is computed by splitting the returned rows on the
  *requested* limit, not the clamped one, so a read asking for more than the
  maximum comes back short AND claims to be complete. A caller has no in-band
  way to tell a truncated page from the end of the data, and the codebase is
  full of adapters that reduce a page to its `results` list, discarding the flag
  entirely.

  This test fails on the declaration rather than waiting for a deployment large
  enough to cross the cap -- which is the only reason the original instance of
  this went unnoticed: every test fixture in the tree is orders of magnitude
  smaller than the limit involved.
  """

  use ExUnit.Case, async: true

  @moduletag :db_free

  test "no read action declares a default_limit above its max_page_size" do
    violations =
      for domain <- domains(),
          resource <- resources(domain),
          action <- Ash.Resource.Info.actions(resource),
          action.type == :read,
          violation = pagination_violation(resource, action),
          not is_nil(violation) do
        violation
      end

    assert violations == [],
           """
           These read actions declare a default_limit larger than their max_page_size.
           Ash clamps the page down silently and then reports the short page as
           complete, so every caller that trusts the result -- or discards the page
           struct and keeps only `results` -- reads truncated data with no error.

           Two remedies, one of which must apply:

           1. If callers must be able to request large pages, declare
              `max_page_size: @unbounded_page_size` (see `Device.read` for the
              module-level constant pattern). An effectively-infinite value removes
              the ceiling entirely rather than moving it. A finite raise only shifts
              the silent cliff to a larger number -- it still fires, more rarely and
              on the biggest installations.

           2. If the action genuinely needs a modest cap, lower `default_limit` to
              something at or below `max_page_size`. Internal callers that need every
              row should use `Ash.stream!/2` instead of reading one page.

           #{Enum.map_join(violations, "\n", &("  - " <> &1))}
           """
  end

  defp domains do
    :serviceradar_core
    |> Application.get_env(:ash_domains, [])
    |> List.wrap()
  end

  defp resources(domain) do
    Ash.Domain.Info.resources(domain)
  rescue
    _ -> []
  end

  # `pagination` is `nil`/`false` on actions that do not paginate, and those
  # cannot exhibit the defect. Only a pair of concrete integers can violate it.
  defp pagination_violation(resource, action) do
    pagination = Map.get(action, :pagination)

    with true <- is_map(pagination),
         default_limit when is_integer(default_limit) <- Map.get(pagination, :default_limit),
         max_page_size when is_integer(max_page_size) <- Map.get(pagination, :max_page_size),
         true <- default_limit > max_page_size do
      "#{inspect(resource)} action :#{action.name} declares default_limit " <>
        "#{default_limit} but max_page_size #{max_page_size}"
    else
      _ -> nil
    end
  end
end
