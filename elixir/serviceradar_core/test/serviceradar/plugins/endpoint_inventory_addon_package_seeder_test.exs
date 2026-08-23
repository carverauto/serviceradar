defmodule ServiceRadar.Plugins.EndpointInventoryAddonPackageSeederTest do
  @moduledoc """
  DB-backed coverage for the ScaLibr endpoint inventory native add-on seed.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.EndpointInventoryAddonPackageSeeder

  require Ash.Query

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    unique_id = :erlang.unique_integer([:positive])

    actor = %{
      id: Ash.UUID.generate(),
      email: "test@serviceradar.local",
      role: :admin
    }

    {:ok, actor: actor, unique_id: unique_id}
  end

  test "seeds approved endpoint inventory package and compiles assignment as a systemd timer",
       %{actor: actor, unique_id: unique_id} do
    version = "0.1.#{unique_id}"
    sha = String.duplicate("b", 64)
    signature = "sig-#{unique_id}"

    object_key =
      "native-addons/scalibr-endpoint-inventory/#{version}/linux/amd64/#{String.duplicate("a", 64)}.tar.gz"

    artifacts = %{
      "linux/amd64" => %{
        "object_key" => object_key,
        "sha256" => sha,
        "signature" => signature
      }
    }

    assert :ok =
             EndpointInventoryAddonPackageSeeder.seed_defaults(
               version: version,
               artifacts: artifacts,
               source_oci_ref:
                 "registry.carverauto.dev/serviceradar/serviceradar-addon-scalibr-endpoint-inventory:sha-test",
               source_oci_digest: "sha256:#{String.duplicate("e", 64)}",
               source_release_tag: "sha-test"
             )

    {:ok, package} = read_package(version, actor)
    assert package.status == :approved
    assert package.addon_id == "scalibr-endpoint-inventory"
    assert package.delivery == :pushed_artifact
    assert package.supervision == :systemd_timer
    assert package.binary == "serviceradar-scalibr-endpoint-inventory"
    assert package.capabilities == ["endpoint-inventory", "software-sbom", "scanner:v1"]
    assert package.approved_capabilities == ["endpoint-inventory", "software-sbom", "scanner:v1"]
    assert package.requires["run_as"] == "root"
    assert package.requires["os_capabilities"] == []
    assert package.config_schema["title"] == "ScaLibr Endpoint Software Inventory Configuration"
    assert package.artifacts["linux/amd64"]["object_key"] == object_key

    agent_uid = "endpoint-inventory-agent-#{unique_id}"

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(
        :register_connected,
        %{
          uid: agent_uid,
          name: "Endpoint Inventory Test Agent #{unique_id}",
          version: "1.4.12",
          host: "127.0.0.1",
          port: 50_051,
          metadata: %{"os" => "linux", "arch" => "amd64"}
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, _assignment} =
      AddonAssignment
      |> Ash.Changeset.for_create(
        :create,
        %{
          agent_uid: agent_uid,
          addon_package_id: package.id,
          enabled: true,
          params: %{
            "enabled" => true,
            "scan_timeout" => "10m",
            "scan_roots" => ["/"]
          }
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, "default")

    assert [addon] = config.addons
    assert addon.addon_id == "scalibr-endpoint-inventory"
    assert addon.enabled == true
    assert addon.delivery == :pushed_artifact
    assert addon.supervision == :systemd_timer
    assert addon.capabilities == ["endpoint-inventory", "software-sbom", "scanner:v1"]
    assert addon.os_capabilities == []
    assert addon.artifact_object_key == object_key
    assert addon.artifact_sha256 == sha
    assert addon.artifact_signature == signature
    assert addon.target_os == "linux"
    assert addon.target_arch == "amd64"
    assert addon.params["enabled"] == true
    assert addon.params["scan_timeout"] == "10m"

    proto = AgentConfigGenerator.to_proto_response(config)
    assert [proto_addon] = proto.addons
    assert proto_addon.addon_id == "scalibr-endpoint-inventory"
    assert proto_addon.delivery == "pushed_artifact"
    assert proto_addon.supervision == "systemd_timer"
    assert proto_addon.artifact_object_key == object_key
    assert proto_addon.artifact_sha256 == sha
    assert proto_addon.artifact_signature == signature
  end

  test "stages manifest version without configured artifacts", %{
    actor: actor,
    unique_id: unique_id
  } do
    version = "0.9.#{unique_id}"

    assert :ok =
             EndpointInventoryAddonPackageSeeder.seed_defaults(version: version, artifacts: %{})

    {:ok, package} = read_package(version, actor)
    assert package.status == :staged
    assert package.artifacts == %{}
    assert package.capabilities == ["endpoint-inventory", "software-sbom", "scanner:v1"]
    assert package.config_schema["title"] == "ScaLibr Endpoint Software Inventory Configuration"

    # No-touch cohort/profile contract: agent_id is runtime-injected by the agent
    # (from its own identity via the runtime profile file), so it must be hidden from
    # the config form and never a required assignment param. The remaining required
    # fields all ship sensible defaults, so a cohort assignment needs zero manual config.
    schema = package.config_schema
    refute "agent_id" in Map.get(schema, "required", [])
    assert schema["properties"]["agent_id"]["x-serviceradar-ui-hidden"] == true
    refute Map.has_key?(schema["properties"]["agent_id"], "default")
    assert schema["properties"]["enabled"]["default"] == true
    assert schema["properties"]["scan_roots"]["default"] == ["/"]
    assert schema["properties"]["scalibr_plugins"]["default"] == ["os/dpkg", "os/rpm", "os/apk"]
    assert schema["properties"]["cadence"]["default"] == "24h"
    assert schema["properties"]["scan_timeout"]["default"] == "5m"
  end

  defp read_package(version, actor) do
    AddonPackage
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(addon_id == "scalibr-endpoint-inventory" and version == ^version)
    |> Ash.read_one(actor: actor)
  end
end
