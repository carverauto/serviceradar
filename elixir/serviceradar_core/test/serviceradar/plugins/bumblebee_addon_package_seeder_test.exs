defmodule ServiceRadar.Plugins.BumblebeeAddonPackageSeederTest do
  @moduledoc """
  DB-backed coverage for the Bumblebee native add-on control-plane seed.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.BumblebeeAddonPackageSeeder

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

  test "seeds approved Bumblebee package and compiles assignment as a systemd-timer pushed artifact",
       %{actor: actor, unique_id: unique_id} do
    version = "0.1.#{unique_id}"
    sha = String.duplicate("b", 64)
    signature = "sig-#{unique_id}"

    object_key =
      "native-addons/bumblebee/#{version}/linux/amd64/#{String.duplicate("a", 64)}.tar.gz"

    artifacts = %{
      "linux/amd64" => %{
        "object_key" => object_key,
        "sha256" => sha,
        "signature" => signature
      },
      "linux/arm64" => %{
        "object_key" =>
          "native-addons/bumblebee/#{version}/linux/arm64/#{String.duplicate("c", 64)}.tar.gz",
        "sha256" => String.duplicate("d", 64),
        "signature" => "sig-arm64-#{unique_id}"
      }
    }

    assert :ok =
             BumblebeeAddonPackageSeeder.seed_defaults(
               version: version,
               artifacts: artifacts,
               source_oci_ref:
                 "registry.carverauto.dev/serviceradar/serviceradar-addon-bumblebee-scan:sha-test",
               source_oci_digest: "sha256:#{String.duplicate("e", 64)}",
               source_release_tag: "sha-test"
             )

    {:ok, package} = read_package(version, actor)
    assert package.status == :approved
    assert package.addon_id == "bumblebee"
    assert package.version == version
    assert package.delivery == :pushed_artifact
    assert package.supervision == :systemd_timer
    assert package.binary == "serviceradar-bumblebee-scan"
    assert package.capabilities == ["exposure-scan"]
    assert package.approved_capabilities == ["exposure-scan"]
    assert package.requires["run_as"] == "root"
    assert package.config_schema["title"] == "Bumblebee Exposure Scanner Configuration"
    assert package.artifacts["linux/amd64"]["object_key"] == object_key

    agent_uid = "bumblebee-agent-#{unique_id}"

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(
        :register_connected,
        %{
          uid: agent_uid,
          name: "Bumblebee Test Agent #{unique_id}",
          version: "1.2.0",
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
            "scan_timeout" => "5m",
            "include_home_roots" => true,
            "include_root" => true
          }
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, "default")

    assert [addon] = config.addons
    assert addon.addon_id == "bumblebee"
    assert addon.enabled == true
    assert addon.delivery == :pushed_artifact
    assert addon.supervision == :systemd_timer
    assert addon.capabilities == ["exposure-scan"]
    assert addon.os_capabilities == []
    assert addon.artifact_object_key == object_key
    assert addon.artifact_sha256 == sha
    assert addon.artifact_signature == signature
    assert addon.target_os == "linux"
    assert addon.target_arch == "amd64"
    assert addon.params["enabled"] == true
    assert addon.params["scan_timeout"] == "5m"

    proto = AgentConfigGenerator.to_proto_response(config)
    assert [proto_addon] = proto.addons
    assert proto_addon.addon_id == "bumblebee"
    assert proto_addon.delivery == "pushed_artifact"
    assert proto_addon.supervision == "systemd_timer"
    assert proto_addon.artifact_object_key == object_key
    assert proto_addon.artifact_sha256 == sha
    assert proto_addon.artifact_signature == signature
  end

  defp read_package(version, actor) do
    AddonPackage
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(addon_id == "bumblebee" and version == ^version)
    |> Ash.read_one(actor: actor)
  end
end
