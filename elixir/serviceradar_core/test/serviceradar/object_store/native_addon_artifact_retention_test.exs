defmodule ServiceRadar.ObjectStore.NativeAddonArtifactRetentionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.ObjectStore.NativeAddonArtifactRetention
  alias ServiceRadar.Plugins.AddonPackage

  describe "plan/4" do
    test "protects active native add-on artifacts" do
      package =
        package(
          "pkg-active",
          :approved,
          "native-addons/scalibr-endpoint-inventory/0.1.1/linux/amd64/sha.tar.gz"
        )

      plan =
        NativeAddonArtifactRetention.plan(
          [package],
          MapSet.new(),
          [object("native-addons/scalibr-endpoint-inventory/0.1.1/linux/amd64/sha.tar.gz")],
          0
        )

      assert [
               %{
                 key: "native-addons/scalibr-endpoint-inventory/0.1.1/linux/amd64/sha.tar.gz",
                 reason: :active_package
               }
             ] =
               plan.protected

      assert plan.eligible == []
    end

    test "protects staged native add-on artifacts during review" do
      package =
        package(
          "pkg-staged",
          :staged,
          "native-addons/scalibr-endpoint-inventory/0.1.1/linux/amd64/staged.tar.gz"
        )

      plan =
        NativeAddonArtifactRetention.plan(
          [package],
          MapSet.new(),
          [object("native-addons/scalibr-endpoint-inventory/0.1.1/linux/amd64/staged.tar.gz")],
          0
        )

      assert [
               %{
                 key: "native-addons/scalibr-endpoint-inventory/0.1.1/linux/amd64/staged.tar.gz",
                 reason: :active_package
               }
             ] =
               plan.protected

      assert plan.eligible == []
    end

    test "protects referenced inactive packages" do
      package =
        package(
          "pkg-referenced",
          :revoked,
          "native-addons/netprobe/0.1.0/linux/amd64/sha.tar.gz"
        )

      plan =
        NativeAddonArtifactRetention.plan(
          [package],
          MapSet.new(["pkg-referenced"]),
          [object("native-addons/netprobe/0.1.0/linux/amd64/sha.tar.gz")],
          0
        )

      assert [
               %{
                 key: "native-addons/netprobe/0.1.0/linux/amd64/sha.tar.gz",
                 reason: :referenced_package
               }
             ] =
               plan.protected

      assert plan.eligible == []
    end

    test "protects verified native add-on artifacts" do
      package =
        package(
          "pkg-verified",
          :staged,
          "native-addons/scalibr-endpoint-inventory/0.1.1/linux/amd64/verified.tar.gz",
          ~U[2026-01-01 00:00:00Z],
          "verified"
        )

      plan =
        NativeAddonArtifactRetention.plan(
          [package],
          MapSet.new(),
          [object("native-addons/scalibr-endpoint-inventory/0.1.1/linux/amd64/verified.tar.gz")],
          0
        )

      assert [
               %{
                 key:
                   "native-addons/scalibr-endpoint-inventory/0.1.1/linux/amd64/verified.tar.gz",
                 reason: :verified_package
               }
             ] =
               plan.protected

      assert plan.eligible == []
    end

    test "does not protect revoked verified packages after grace" do
      package =
        package(
          "pkg-revoked-verified",
          :revoked,
          "native-addons/scalibr-endpoint-inventory/0.1.1/linux/amd64/revoked-verified.tar.gz",
          ~U[2026-01-01 00:00:00Z],
          "verified"
        )

      plan =
        NativeAddonArtifactRetention.plan(
          [package],
          MapSet.new(),
          [
            object(
              "native-addons/scalibr-endpoint-inventory/0.1.1/linux/amd64/revoked-verified.tar.gz"
            )
          ],
          0
        )

      assert [
               %{
                 key:
                   "native-addons/scalibr-endpoint-inventory/0.1.1/linux/amd64/revoked-verified.tar.gz",
                 reason: :inactive_package
               }
             ] = plan.eligible

      assert plan.protected == []
    end

    test "deletes orphaned native add-on artifacts after grace" do
      old_created_at =
        DateTime.utc_now()
        |> DateTime.add(-8, :day)
        |> DateTime.to_unix()

      plan =
        NativeAddonArtifactRetention.plan(
          [],
          MapSet.new(),
          [object("native-addons/orphan/0.1.0/linux/amd64/sha.tar.gz", old_created_at)],
          7 * 24 * 60 * 60
        )

      assert [
               %{
                 key: "native-addons/orphan/0.1.0/linux/amd64/sha.tar.gz",
                 reason: :orphaned_object
               }
             ] =
               plan.eligible
    end

    test "deletes orphaned native add-on artifacts from datasvc object info after grace" do
      old_created_at =
        DateTime.utc_now()
        |> DateTime.add(-8, :day)
        |> DateTime.to_unix()

      key = "native-addons/orphan-proto/0.1.0/linux/amd64/sha.tar.gz"

      plan =
        NativeAddonArtifactRetention.plan(
          [],
          MapSet.new(),
          [
            %Proto.ObjectInfo{
              metadata: %Proto.ObjectMetadata{key: key},
              created_at_unix: old_created_at
            }
          ],
          7 * 24 * 60 * 60
        )

      assert [%{key: ^key, reason: :orphaned_object}] = plan.eligible
    end

    test "protects orphaned native add-on artifacts inside grace" do
      recent_created_at =
        DateTime.utc_now()
        |> DateTime.add(-1, :hour)
        |> DateTime.to_unix()

      plan =
        NativeAddonArtifactRetention.plan(
          [],
          MapSet.new(),
          [object("native-addons/orphan/0.1.0/linux/amd64/sha.tar.gz", recent_created_at)],
          7 * 24 * 60 * 60
        )

      assert [
               %{
                 key: "native-addons/orphan/0.1.0/linux/amd64/sha.tar.gz",
                 reason: :grace_period
               }
             ] =
               plan.protected

      assert plan.eligible == []
    end

    test "protects orphaned native add-on artifacts with unusable timestamps" do
      plan =
        NativeAddonArtifactRetention.plan(
          [],
          MapSet.new(),
          [object("native-addons/orphan/0.1.0/linux/amd64/sha.tar.gz", -1)],
          7 * 24 * 60 * 60
        )

      assert [
               %{
                 key: "native-addons/orphan/0.1.0/linux/amd64/sha.tar.gz",
                 reason: :grace_period
               }
             ] =
               plan.protected

      assert plan.eligible == []
    end

    test "deletes inactive packages only after grace" do
      old_package =
        package(
          "pkg-denied-old",
          :denied,
          "native-addons/old/0.1.0/linux/amd64/sha.tar.gz"
        )

      recent_package =
        package(
          "pkg-denied-recent",
          :denied,
          "native-addons/recent/0.1.0/linux/amd64/sha.tar.gz",
          DateTime.utc_now()
        )

      plan =
        NativeAddonArtifactRetention.plan(
          [old_package, recent_package],
          MapSet.new(),
          [
            object("native-addons/old/0.1.0/linux/amd64/sha.tar.gz"),
            object("native-addons/recent/0.1.0/linux/amd64/sha.tar.gz")
          ],
          7 * 24 * 60 * 60
        )

      assert [%{key: "native-addons/old/0.1.0/linux/amd64/sha.tar.gz", reason: :inactive_package}] =
               plan.eligible

      assert [%{key: "native-addons/recent/0.1.0/linux/amd64/sha.tar.gz", reason: :grace_period}] =
               plan.protected
    end

    test "protects duplicate artifact references when any package is active" do
      object_key = "native-addons/shared/0.1.0/linux/amd64/sha.tar.gz"
      old_denied = package("pkg-denied-old", :denied, object_key)
      approved = package("pkg-approved", :approved, object_key)

      plan =
        NativeAddonArtifactRetention.plan(
          [old_denied, approved],
          MapSet.new(),
          [object(object_key)],
          7 * 24 * 60 * 60
        )

      assert [%{key: ^object_key, reason: :active_package}] = plan.protected
      assert plan.eligible == []
    end

    test "protects duplicate artifact references when any package is assigned" do
      object_key = "native-addons/shared/0.1.0/linux/amd64/sha.tar.gz"
      old_denied = package("pkg-denied-old", :denied, object_key)
      old_revoked = package("pkg-revoked-old", :revoked, object_key)

      plan =
        NativeAddonArtifactRetention.plan(
          [old_denied, old_revoked],
          MapSet.new(["pkg-revoked-old"]),
          [object(object_key)],
          7 * 24 * 60 * 60
        )

      assert [%{key: ^object_key, reason: :referenced_package}] = plan.protected
      assert plan.eligible == []
    end

    test "deletes duplicate artifact references when every package is old and inactive" do
      object_key = "native-addons/shared/0.1.0/linux/amd64/sha.tar.gz"
      old_denied = package("pkg-denied-old", :denied, object_key)
      old_revoked = package("pkg-revoked-old", :revoked, object_key)

      plan =
        NativeAddonArtifactRetention.plan(
          [old_denied, old_revoked],
          MapSet.new(),
          [object(object_key)],
          7 * 24 * 60 * 60
        )

      assert [%{key: ^object_key, reason: :inactive_package}] = plan.eligible
      assert plan.protected == []
    end
  end

  describe "artifact_keys/1" do
    test "extracts object keys from per-platform artifacts" do
      package =
        %AddonPackage{
          artifacts: %{
            "linux/amd64" => %{"object_key" => "native-addons/addon/1/linux/amd64/a.tar.gz"},
            "linux/arm64" => %{object_key: "native-addons/addon/1/linux/arm64/a.tar.gz"}
          }
        }

      assert Enum.sort(NativeAddonArtifactRetention.artifact_keys(package)) == [
               "native-addons/addon/1/linux/amd64/a.tar.gz",
               "native-addons/addon/1/linux/arm64/a.tar.gz"
             ]
    end

    test "normalizes object keys and drops blank entries" do
      package =
        %AddonPackage{
          artifacts: %{
            "linux/amd64" => %{"object_key" => " native-addons/addon/1/linux/amd64/a.tar.gz "},
            "linux/arm64" => %{object_key: "   "},
            "linux/arm/v7" => %{"object_key" => nil}
          }
        }

      assert NativeAddonArtifactRetention.artifact_keys(package) == [
               "native-addons/addon/1/linux/amd64/a.tar.gz"
             ]
    end
  end

  defp package(
         id,
         status,
         object_key,
         updated_at \\ ~U[2026-01-01 00:00:00Z],
         verification_status \\ nil
       ) do
    %AddonPackage{
      id: id,
      addon_id: "endpoint-inventory",
      version: "0.1.1",
      name: "Endpoint Inventory",
      status: status,
      verification_status: verification_status,
      artifacts: %{"linux/amd64" => %{"object_key" => object_key}},
      inserted_at: ~U[2026-01-01 00:00:00Z],
      updated_at: updated_at
    }
  end

  defp object(key, created_at_unix \\ nil) do
    %{metadata: %{key: key}, created_at_unix: created_at_unix}
  end
end
