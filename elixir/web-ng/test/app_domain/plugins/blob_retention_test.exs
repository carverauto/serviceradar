defmodule ServiceRadarWebNG.Plugins.BlobRetentionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadarWebNG.Plugins.BlobRetention

  describe "plan/4" do
    test "protects active packages and referenced inactive packages" do
      approved =
        package(
          "pkg-approved",
          :approved,
          "plugins/unifi/1.0.0/plugin.wasm",
          ~U[2000-01-01 00:00:00Z]
        )

      referenced =
        package(
          "pkg-referenced",
          :revoked,
          "plugins/alienvault/1.0.0/plugin.wasm",
          ~U[2000-01-01 00:00:00Z]
        )

      plan =
        BlobRetention.plan(
          [approved, referenced],
          MapSet.new(["pkg-referenced"]),
          [
            blob("plugins/unifi/1.0.0/plugin.wasm"),
            blob("plugins/alienvault/1.0.0/plugin.wasm")
          ],
          60
        )

      assert Enum.find(plan.protected, &(&1.key == "plugins/unifi/1.0.0/plugin.wasm")).reason ==
               :active_package

      assert Enum.find(plan.protected, &(&1.key == "plugins/alienvault/1.0.0/plugin.wasm")).reason ==
               :referenced_package

      assert plan.eligible == []
    end

    test "deletes inactive packages outside grace and orphaned blobs" do
      stale =
        package("pkg-stale", :denied, "plugins/old/1.0.0/plugin.wasm", ~U[2000-01-01 00:00:00Z])

      plan =
        BlobRetention.plan(
          [stale],
          MapSet.new(),
          [
            blob("plugins/old/1.0.0/plugin.wasm"),
            blob("plugins/orphan/1.0.0/plugin.wasm")
          ],
          60
        )

      assert Enum.find(plan.eligible, &(&1.key == "plugins/old/1.0.0/plugin.wasm")).reason ==
               :inactive_package

      assert Enum.find(plan.eligible, &(&1.key == "plugins/orphan/1.0.0/plugin.wasm")).reason ==
               :orphaned_blob
    end

    test "keeps inactive packages inside the grace period" do
      recent =
        package(
          "pkg-recent",
          :denied,
          "plugins/recent/1.0.0/plugin.wasm",
          ~U[2999-01-01 00:00:00Z]
        )

      plan =
        BlobRetention.plan(
          [recent],
          MapSet.new(),
          [blob("plugins/recent/1.0.0/plugin.wasm")],
          604_800
        )

      assert [%{key: "plugins/recent/1.0.0/plugin.wasm", reason: :grace_period}] = plan.protected
      assert plan.eligible == []
    end
  end

  defp package(id, status, object_key, updated_at) do
    %PluginPackage{
      id: id,
      plugin_id: "test-plugin-#{id}",
      name: "Test Plugin #{id}",
      version: "1.0.0",
      entrypoint: "main",
      outputs: "status",
      status: status,
      wasm_object_key: object_key,
      inserted_at: updated_at,
      updated_at: updated_at
    }
  end

  defp blob(key), do: %{key: key}
end
