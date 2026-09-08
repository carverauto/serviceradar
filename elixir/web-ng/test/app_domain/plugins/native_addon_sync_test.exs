defmodule ServiceRadarWebNG.Plugins.NativeAddonSyncTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Plugins.NativeAddonSync

  @moduletag :db_free

  test "unattended sync selects the newest import-ready release as one set" do
    addons = [
      candidate("anomaly", "0.3.1", "v1.4.24"),
      candidate("powerdns", "0.1.3", "v1.4.24"),
      candidate("anomaly", "0.3.0", "v1.4.23"),
      candidate("netprobe", "0.2.24", "v1.4.23")
    ]

    assert NativeAddonSync.candidates(addons) == Enum.take(addons, 2)
  end

  test "sync can explicitly select one historical release" do
    addons = [
      candidate("anomaly", "0.3.1", "v1.4.24"),
      candidate("anomaly", "0.3.0", "v1.4.23"),
      candidate("netprobe", "0.2.24", "v1.4.23")
    ]

    assert NativeAddonSync.candidates(addons, release_tag: "v1.4.23") == Enum.drop(addons, 1)
  end

  test "unattended sync does not fill a partial latest release from history" do
    addons = [
      candidate("anomaly", "0.3.1", "v1.4.24"),
      candidate("netprobe", "0.2.24", "v1.4.23")
    ]

    assert NativeAddonSync.candidates(addons, addon_ids: ["netprobe"]) == []
  end

  test "unattended sync skips an incomplete newest release entry" do
    addons = [
      candidate("anomaly", "0.3.1", "v1.4.24", false),
      candidate("anomaly", "0.3.0", "v1.4.23")
    ]

    assert NativeAddonSync.candidates(addons) == Enum.drop(addons, 1)
  end

  defp candidate(addon_id, version, release_tag, import_ready? \\ true) do
    %{
      addon_id: addon_id,
      version: version,
      release_tag: release_tag,
      import_ready?: import_ready?
    }
  end
end
