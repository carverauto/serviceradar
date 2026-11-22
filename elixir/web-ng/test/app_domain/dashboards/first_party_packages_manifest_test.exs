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
    "network-performance",
    "web-rum"
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

    for entity <- ["netperf", "netperf_metrics", "agents"] do
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

    assert is_number(sample_settings["lossAlertThresholdPct"])
    assert is_number(sample_settings["jitterAlertThresholdMs"])

    rows = Enum.flat_map(sample_frames, & &1["results"])

    ips =
      rows
      |> Enum.flat_map(&[&1["target_device_ip"], &1["ip"], sample_row_tags(&1)["target"]])
      |> Enum.reject(&is_nil/1)

    hosts = rows |> Enum.map(& &1["host"]) |> Enum.reject(&is_nil/1)

    assert ips != []
    assert hosts != []

    for ip <- ips do
      assert rfc5737_documentation_ip?(ip), "non-RFC 5737 address in sample frames: #{ip}"
    end

    for host <- hosts do
      assert String.ends_with?(host, ".example.com"),
             "non-example.com host in sample frames: #{host}"
    end
  end

  test "web-rum manifest declares built_in Blueprint host contract and supported rum/websites entities" do
    manifest_json =
      [@package_root, "web-rum", "manifest.json"]
      |> Path.join()
      |> File.read!()

    assert {:ok, manifest} = Manifest.from_json(manifest_json)
    assert manifest.id == "cloud.serviceradar.web-rum"
    assert manifest.renderer["kind"] == "built_in"
    assert manifest.renderer["interface_version"] == "dashboard-built-in-v1"
    assert manifest.renderer["trust"] == "first_party"
    assert manifest.renderer["artifact"] == "web-rum"
    assert manifest.renderer["entrypoint"] == "web_rum"
    assert Regex.match?(~r/^[0-9a-f]{64}$/, manifest.renderer["sha256"])

    for entity <- ["rum", "rum_beacons", "rum_beacon", "websites", "website", "web_properties", "web_property"] do
      rewritten =
        manifest_json
        |> Jason.decode!()
        |> put_in(["data_frames", Access.at!(0), "query"], "in:#{entity} limit:10")
        |> Jason.encode!()

      assert {:ok, parsed} = Manifest.from_json(rewritten)
      assert :ok = FirstPartyPackages.validate_first_party_manifest(parsed)
    end
  end

  test "web-rum sample frames and settings align with manifest using synthetic RFC 5737 fixtures" do
    manifest =
      [@package_root, "web-rum", "manifest.json"]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()

    sample_frames =
      [@package_root, "web-rum", "sample-frames.json"]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()

    sample_settings =
      [@package_root, "web-rum", "sample-settings.json"]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()

    assert is_list(sample_frames)
    assert MapSet.new(manifest["data_frames"], & &1["id"]) == MapSet.new(sample_frames, & &1["id"])

    assert sample_settings["defaultWindow"] == "last_24h"
    assert sample_settings["lcpGoodThresholdMs"] == 2500
    assert sample_settings["inpGoodThresholdMs"] == 200
    assert sample_settings["clsGoodThreshold"] == 0.1

    raw_frames_text = Jason.encode!(sample_frames)
    assert raw_frames_text =~ "192.0.2."
    assert raw_frames_text =~ "198.51.100."
    assert raw_frames_text =~ "203.0.113."
    assert raw_frames_text =~ ".example.com"
    assert raw_frames_text =~ "64512"
  end

  defp sample_row_tags(%{"tags" => tags}) when is_binary(tags), do: Jason.decode!(tags)
  defp sample_row_tags(%{"tags" => tags}) when is_map(tags), do: tags
  defp sample_row_tags(_row), do: %{}

  defp rfc5737_documentation_ip?(ip) when is_binary(ip) do
    case :inet.parse_ipv4strict_address(String.to_charlist(ip)) do
      {:ok, {192, 0, 2, _}} -> true
      {:ok, {198, 51, 100, _}} -> true
      {:ok, {203, 0, 113, _}} -> true
      _ -> false
    end
  end

  defp rfc5737_documentation_ip?(_ip), do: false
end
