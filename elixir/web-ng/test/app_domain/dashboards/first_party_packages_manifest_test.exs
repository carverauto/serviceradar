defmodule ServiceRadarWebNG.Dashboards.FirstPartyPackagesManifestTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Dashboards.Manifest
  alias ServiceRadarWebNG.Dashboards.FirstPartyPackages

  @moduletag :db_free

  @package_root Path.expand("../../../priv/dashboard-packages", __DIR__)
  @package_slugs [
    "service-availability-noc",
    "security-findings",
    "endpoint-inventory",
    "network-performance"
  ]

  test "all bundled first-party manifests parse and pass entity validation" do
    for slug <- @package_slugs do
      manifest_path = Path.join([@package_root, slug, "manifest.json"])

      assert {:ok, manifest} =
               manifest_path
               |> File.read!()
               |> Manifest.from_json()

      assert :ok = FirstPartyPackages.validate_first_party_manifest(manifest)
    end
  end

  test "network-performance manifest declares built_in Blueprint host contract and supported entities" do
    manifest_json =
      [@package_root, "network-performance", "manifest.json"]
      |> Path.join()
      |> File.read!()

    assert {:ok, manifest} = Manifest.from_json(manifest_json)
    assert manifest.id == "cloud.serviceradar.network-performance"
    assert manifest.renderer["kind"] == "built_in"
    assert manifest.renderer["interface_version"] == "dashboard-built-in-v1"
    assert manifest.renderer["trust"] == "first_party"
    assert manifest.renderer["artifact"] == "network-performance"
    assert manifest.renderer["entrypoint"] == "network_performance"
    assert Regex.match?(~r/^[0-9a-f]{64}$/, manifest.renderer["sha256"])

    for entity <- ["netperf", "netperf_metrics", "rperf", "rperf_metrics", "agents"] do
      rewritten =
        manifest_json
        |> Jason.decode!()
        |> put_in(["data_frames", Access.at!(0), "query"], "in:#{entity} limit:10")
        |> Jason.encode!()

      assert {:ok, parsed} = Manifest.from_json(rewritten)
      assert :ok = FirstPartyPackages.validate_first_party_manifest(parsed)
    end
  end

  test "first-party manifest validation rejects unsupported required entities" do
    manifest_json =
      [@package_root, "network-performance", "manifest.json"]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["data_frames", Access.at!(0), "query"], "in:unsupported_net_entity limit:5")
      |> Jason.encode!()

    assert {:ok, manifest} = Manifest.from_json(manifest_json)

    assert {:error, {:unsupported_first_party_dashboard_frame_entity, "netperf_recent_samples", "unsupported_net_entity"}} =
             FirstPartyPackages.validate_first_party_manifest(manifest)
  end

  test "network-performance sample frames and settings align with manifest using synthetic RFC 5737 fixtures" do
    manifest =
      [@package_root, "network-performance", "manifest.json"]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()

    sample_frames =
      [@package_root, "network-performance", "sample-frames.json"]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()

    sample_settings =
      [@package_root, "network-performance", "sample-settings.json"]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()

    assert is_list(sample_frames)

    manifest_frame_ids = MapSet.new(manifest["data_frames"], & &1["id"])
    sample_frame_ids = MapSet.new(sample_frames, & &1["id"])
    assert manifest_frame_ids == sample_frame_ids

    assert sample_settings["defaultWindow"] == "last_24h"
    assert is_number(sample_settings["lossAlertThresholdPct"])
    assert is_number(sample_settings["jitterAlertThresholdMs"])

    raw_frames_text = Jason.encode!(sample_frames)
    assert raw_frames_text =~ "192.0.2."
    assert raw_frames_text =~ "198.51.100."
    assert raw_frames_text =~ "203.0.113."
    assert raw_frames_text =~ ".example."
  end
end
