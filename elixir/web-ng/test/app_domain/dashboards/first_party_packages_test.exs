defmodule ServiceRadarWebNG.Dashboards.FirstPartyPackagesTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Dashboards.Manifest
  alias ServiceRadarWebNG.Dashboards.FirstPartyPackages

  @manifest_path Path.expand(
                   "../../../priv/dashboard-packages/service-availability-noc/manifest.json",
                   __DIR__
                 )

  test "bundled Service Availability NOC frames target supported SRQL entities" do
    assert {:ok, manifest} =
             @manifest_path
             |> File.read!()
             |> Manifest.from_json()

    assert :ok = FirstPartyPackages.validate_first_party_manifest(manifest)
  end

  test "first-party package validation rejects unsupported required frame entities" do
    manifest_json =
      @manifest_path
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["data_frames", Access.at!(0), "query"], "in:not_real_entity limit:1")
      |> Jason.encode!()

    assert {:ok, manifest} = Manifest.from_json(manifest_json)

    assert {:error, {:unsupported_first_party_dashboard_frame_entity, "availability_rollup", "not_real_entity"}} =
             FirstPartyPackages.validate_first_party_manifest(manifest)
  end
end
