defmodule ServiceRadarWebNG.Plugins.BlobRetentionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadarWebNG.Plugins.BlobRetention

  @old_unix DateTime.to_unix(~U[2000-01-01 00:00:00Z])

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

    test "deletes inactive packages outside grace and aged orphaned blobs" do
      stale =
        package("pkg-stale", :denied, "plugins/old/1.0.0/plugin.wasm", ~U[2000-01-01 00:00:00Z])

      plan =
        BlobRetention.plan(
          [stale],
          MapSet.new(),
          [
            blob("plugins/old/1.0.0/plugin.wasm"),
            blob("plugins/orphan/1.0.0/plugin.wasm", @old_unix)
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

    test "protects an orphaned blob whose package is still assigned to an agent" do
      # The PluginPackage row is gone, but an enabled assignment/policy still
      # references the package id parsed from the key, so the agent still fetches it.
      plan =
        BlobRetention.plan(
          [],
          MapSet.new(["pkg-ghost"]),
          [blob("plugins/ghost/1.0.0/pkg-ghost.wasm", @old_unix)],
          60
        )

      assert [%{key: "plugins/ghost/1.0.0/pkg-ghost.wasm", reason: :referenced_orphan}] =
               plan.protected

      assert plan.eligible == []
    end

    test "keeps orphaned blobs of unknown or recent age inside the grace period" do
      now_unix = DateTime.to_unix(DateTime.utc_now())

      plan =
        BlobRetention.plan(
          [],
          MapSet.new(),
          [
            blob("plugins/unknown/1.0.0/plugin.wasm"),
            blob("plugins/fresh/1.0.0/plugin.wasm", now_unix)
          ],
          604_800
        )

      assert Enum.all?(plan.protected, &(&1.reason == :grace_period))

      protected_keys = plan.protected |> Enum.map(& &1.key) |> Enum.sort()

      assert protected_keys == [
               "plugins/fresh/1.0.0/plugin.wasm",
               "plugins/unknown/1.0.0/plugin.wasm"
             ]

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
  defp blob(key, created_at_unix), do: %{key: key, created_at_unix: created_at_unix}
end
