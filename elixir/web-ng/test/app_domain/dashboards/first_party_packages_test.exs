defmodule ServiceRadarWebNG.Dashboards.FirstPartyPackagesTest do
  use ServiceRadarWebNG.DataCase, async: false

  import ServiceRadarWebNG.AshTestHelpers, only: [system_actor: 0]

  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadarWebNG.Dashboards.FirstPartyPackages

  require Ash.Query

  test "seeds the service availability NOC dashboard as an enabled first-party package" do
    assert {:ok, %{package: %DashboardPackage{} = package, instance: %DashboardInstance{} = instance}} =
             FirstPartyPackages.ensure_service_availability_noc(actor: system_actor())

    assert package.dashboard_id == "cloud.serviceradar.service-availability-noc"
    assert package.source_type == :first_party
    assert package.status == :enabled
    assert package.verification_status == "verified"
    assert package.wasm_object_key == "first-party://dashboard-packages/service-availability-noc/renderer.js"

    assert instance.route_slug == "service-availability-noc"
    assert instance.enabled
    assert instance.placement == :dashboard
    assert instance.is_default

    assert {:ok, {:binary, renderer}} = FirstPartyPackages.fetch_renderer(package)
    assert byte_size(renderer) > 0
  end

  test "re-seeding preserves existing route settings while keeping the route enabled" do
    actor = system_actor()

    assert {:ok, %{instance: instance}} = FirstPartyPackages.ensure_service_availability_noc(actor: actor)

    assert {:ok, _updated} =
             instance
             |> Ash.Changeset.for_update(:update, %{
               enabled: false,
               settings: %{"defaultNocTag" => "database"}
             })
             |> Ash.update(actor: actor)

    assert {:ok, %{instance: reseeded}} = FirstPartyPackages.ensure_service_availability_noc(actor: actor)

    assert reseeded.enabled
    assert reseeded.settings == %{"defaultNocTag" => "database"}
  end
end
