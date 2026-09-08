defmodule ServiceRadarWebNG.Dashboards.FirstPartyPackagesTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadar.Dashboards.Manifest
  alias ServiceRadarWebNG.Dashboards.FirstPartyPackages

  require Ash.Query

  @manifest_paths [
    "../../../priv/dashboard-packages/service-availability-noc/manifest.json",
    "../../../priv/dashboard-packages/security-findings/manifest.json",
    "../../../priv/dashboard-packages/endpoint-inventory/manifest.json"
  ]
  @manifest_path @manifest_paths |> List.first() |> Path.expand(__DIR__)

  test "bundled first-party dashboard frames target supported SRQL entities" do
    for manifest_path <- Enum.map(@manifest_paths, &Path.expand(&1, __DIR__)) do
      assert {:ok, manifest} =
               manifest_path
               |> File.read!()
               |> Manifest.from_json()

      assert :ok = FirstPartyPackages.validate_first_party_manifest(manifest)
    end
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

  @tag :tmp_dir
  test "first-party package seeding is idempotent and updates an existing route on package changes", %{
    tmp_dir: tmp_dir
  } do
    actor = SystemActor.system(:first_party_dashboard_seeder_test)
    package_dir = copy_package_dir!("security-findings", tmp_dir)

    assert {:ok, %{package: package, instance: instance}} =
             FirstPartyPackages.ensure_security_findings(actor: actor, package_dir: package_dir)

    assert package.dashboard_id == "cloud.serviceradar.security-findings"
    assert package.status == :enabled
    assert package.source_type == :first_party
    assert package.source_metadata["source"] == "first_party"
    assert package.source_metadata["route_slug"] == "security-findings"
    assert instance.route_slug == "security-findings"
    assert instance.dashboard_package_id == package.id
    assert instance.enabled

    assert {:ok, %{package: same_package, instance: same_instance}} =
             FirstPartyPackages.ensure_security_findings(actor: actor, package_dir: package_dir)

    assert same_package.id == package.id
    assert same_instance.id == instance.id
    assert same_instance.dashboard_package_id == package.id

    update_manifest!(package_dir, %{
      "version" => "0.1.1-test",
      "name" => "Security Findings Updated",
      "description" => "Updated through the first-party seeder test"
    })

    assert {:ok, %{package: updated_package, instance: updated_instance}} =
             FirstPartyPackages.ensure_security_findings(actor: actor, package_dir: package_dir)

    assert updated_package.id != package.id
    assert updated_package.version == "0.1.1-test"
    assert updated_package.name == "Security Findings Updated"
    assert updated_package.status == :enabled
    assert updated_instance.id == instance.id
    assert updated_instance.name == "Security Findings Updated"
    assert updated_instance.dashboard_package_id == updated_package.id
    assert updated_instance.metadata["source"] == "first_party"

    packages =
      DashboardPackage
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(dashboard_id == "cloud.serviceradar.security-findings")
      |> Ash.read!(actor: actor)

    assert Enum.count(packages) == 2

    route_instances =
      DashboardInstance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(route_slug == "security-findings")
      |> Ash.read!(actor: actor)

    assert Enum.map(route_instances, & &1.id) == [instance.id]
  end

  defp copy_package_dir!(slug, tmp_dir) do
    source_dir = Path.expand("../../../priv/dashboard-packages/#{slug}", __DIR__)

    package_dir = Path.join(tmp_dir, slug)
    File.mkdir_p!(package_dir)

    source_dir
    |> File.ls!()
    |> Enum.each(fn filename ->
      File.cp!(Path.join(source_dir, filename), Path.join(package_dir, filename))
    end)

    package_dir
  end

  defp update_manifest!(package_dir, updates) do
    manifest_path = Path.join(package_dir, "manifest.json")

    manifest_path
    |> File.read!()
    |> Jason.decode!()
    |> Map.merge(updates)
    |> Jason.encode!(pretty: true)
    |> then(&File.write!(manifest_path, &1))
  end
end
