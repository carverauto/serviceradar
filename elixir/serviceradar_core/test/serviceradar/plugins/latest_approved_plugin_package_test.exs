defmodule ServiceRadar.Plugins.LatestApprovedPluginPackageTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.LatestApprovedPluginPackage

  test "orders by semantic version, then approval and import time" do
    earlier = ~U[2026-01-01 00:00:00.000000Z]
    later = ~U[2026-02-01 00:00:00.000000Z]

    packages = [
      %{id: "invalid", version: "nightly"},
      %{id: "minor-9", version: "1.9.0", approved_at: later},
      %{id: "prerelease", version: "1.10.0-rc.1", approved_at: later},
      %{id: "approved-earlier", version: "1.10.0", approved_at: earlier},
      %{id: "approved-later", version: "v1.10.0", approved_at: later},
      %{id: "imported-later", version: "1.10.0", approved_at: earlier, imported_at: later},
      %{"id" => "manifest-only", "manifest" => %{"version" => "1.9.1"}}
    ]

    assert packages
           |> LatestApprovedPluginPackage.newest_first()
           |> Enum.map(&(&1[:id] || &1["id"])) == [
             "approved-later",
             "imported-later",
             "approved-earlier",
             "prerelease",
             "manifest-only",
             "minor-9",
             "invalid"
           ]
  end
end
