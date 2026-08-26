defmodule ServiceRadar.Plugins.NetprobeAddonPackageSeederTest do
  @moduledoc """
  DB-backed coverage for the netprobe native add-on control-plane seed.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.NetprobeAddonPackageSeeder

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

  test "seeds approved netprobe package and compiles assignment as a systemd-service pushed artifact",
       %{actor: actor, unique_id: unique_id} do
    version = "0.1.#{unique_id}"
    sha = String.duplicate("b", 64)
    signature = "sig-#{unique_id}"

    object_key =
      "native-addons/netprobe/#{version}/linux/amd64/#{String.duplicate("a", 64)}.tar.gz"

    artifacts = %{
      "linux/amd64" => %{
        "object_key" => object_key,
        "sha256" => sha,
        "signature" => signature
      },
      "linux/arm64" => %{
        "object_key" =>
          "native-addons/netprobe/#{version}/linux/arm64/#{String.duplicate("c", 64)}.tar.gz",
        "sha256" => String.duplicate("d", 64),
        "signature" => "sig-arm64-#{unique_id}"
      }
    }

    assert :ok =
             NetprobeAddonPackageSeeder.seed_defaults(
               version: version,
               artifacts: artifacts,
               source_oci_ref:
                 "registry.carverauto.dev/serviceradar/serviceradar-addon-netprobe:sha-test",
               source_oci_digest: "sha256:#{String.duplicate("e", 64)}",
               source_release_tag: "sha-test"
             )

    {:ok, package} = read_package(version, actor)
    assert package.status == :approved
    assert package.addon_id == "netprobe"
    assert package.version == version
    assert package.delivery == :pushed_artifact
    assert package.supervision == :systemd_service
    assert package.binary == "serviceradar-netprobe"
    assert package.capabilities == ["host-network-visibility"]
    assert package.approved_capabilities == ["host-network-visibility"]
    assert package.requires["run_as"] == "serviceradar"
    assert package.requires["agent_capabilities"] == ["host-network-visibility"]

    assert package.requires["os_capabilities"] == [
             "CAP_NET_RAW",
             "CAP_NET_ADMIN",
             "CAP_BPF",
             "CAP_PERFMON"
           ]

    assert package.config_schema["title"] == "Host Network Visibility (netprobe) Configuration"
    assert package.artifacts["linux/amd64"]["object_key"] == object_key

    agent_uid = "netprobe-agent-#{unique_id}"

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(
        :register_connected,
        %{
          uid: agent_uid,
          name: "Netprobe Test Agent #{unique_id}",
          version: "1.4.8",
          capabilities: ["host-network-visibility"],
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
            "capture_interfaces" => ["eth0"]
          }
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, "default")

    assert [addon] = config.addons
    assert addon.addon_id == "netprobe"
    assert addon.enabled == true
    assert addon.delivery == :pushed_artifact
    assert addon.supervision == :systemd_service
    assert addon.capabilities == ["host-network-visibility"]
    assert addon.os_capabilities == ["CAP_NET_RAW", "CAP_NET_ADMIN", "CAP_BPF", "CAP_PERFMON"]
    assert addon.artifact_object_key == object_key
    assert addon.artifact_sha256 == sha
    assert addon.artifact_signature == signature
    assert addon.target_os == "linux"
    assert addon.target_arch == "amd64"
    assert addon.params["enabled"] == true
    assert addon.params["capture_interfaces"] == ["eth0"]

    proto = AgentConfigGenerator.to_proto_response(config)
    assert [proto_addon] = proto.addons
    assert proto_addon.addon_id == "netprobe"
    assert proto_addon.delivery == "pushed_artifact"
    assert proto_addon.supervision == "systemd_service"
    assert proto_addon.artifact_object_key == object_key
    assert proto_addon.artifact_sha256 == sha
    assert proto_addon.artifact_signature == signature
  end

  test "stages the manifest version without configured artifacts", %{
    actor: actor,
    unique_id: unique_id
  } do
    version = "0.9.#{unique_id}"

    assert :ok = NetprobeAddonPackageSeeder.seed_defaults(version: version, artifacts: %{})

    {:ok, package} = read_package(version, actor)
    assert package.status == :staged
    assert package.artifacts == %{}
    assert package.source_oci_ref == nil
    assert package.source_oci_digest == nil
    assert package.capabilities == ["host-network-visibility"]
    assert package.requires["agent_capabilities"] == ["host-network-visibility"]
    assert package.config_schema["title"] == "Host Network Visibility (netprobe) Configuration"
  end

  defp read_package(version, actor) do
    AddonPackage
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(addon_id == "netprobe" and version == ^version)
    |> Ash.read_one(actor: actor)
  end
end
