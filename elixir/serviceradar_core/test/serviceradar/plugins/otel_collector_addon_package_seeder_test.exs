defmodule ServiceRadar.Plugins.OtelCollectorAddonPackageSeederTest do
  @moduledoc """
  DB-backed coverage for the otel-collector native add-on control-plane seed.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.OtelCollectorAddonPackageSeeder

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

  test "seeds approved otel-collector package and compiles assignment as an agent-sidecar pushed artifact",
       %{actor: actor, unique_id: unique_id} do
    version = "0.1.#{unique_id}"
    sha = String.duplicate("b", 64)
    signature = "sig-#{unique_id}"

    object_key =
      "native-addons/otel-collector/#{version}/linux/amd64/#{String.duplicate("a", 64)}.tar.gz"

    artifacts = %{
      "linux/amd64" => %{
        "object_key" => object_key,
        "sha256" => sha,
        "signature" => signature
      }
    }

    assert :ok =
             OtelCollectorAddonPackageSeeder.seed_defaults(
               version: version,
               artifacts: artifacts,
               source_oci_ref:
                 "registry.carverauto.dev/serviceradar/serviceradar-addon-otel-collector:sha-test",
               source_oci_digest: "sha256:#{String.duplicate("e", 64)}",
               source_release_tag: "sha-test"
             )

    {:ok, package} = read_package(version, actor)
    assert package.status == :approved
    assert package.addon_id == "otel-collector"
    assert package.version == version
    assert package.delivery == :pushed_artifact
    assert package.supervision == :agent_sidecar
    assert package.binary == "serviceradar-otel-addon"
    assert package.capabilities == ["otlp-relay:v1", "native-telemetry:v1"]
    assert package.approved_capabilities == ["otlp-relay:v1", "native-telemetry:v1"]
    assert package.requires["run_as"] == "serviceradar"
    assert package.requires["os_capabilities"] == []
    assert package.config_schema["title"] == "OTEL Collector Add-on Configuration"
    assert package.artifacts["linux/amd64"]["object_key"] == object_key

    agent_uid = "otel-collector-agent-#{unique_id}"

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(
        :register_connected,
        %{
          uid: agent_uid,
          name: "OTEL Collector Test Agent #{unique_id}",
          host: "127.0.0.1",
          port: 50_051,
          # The package requires base_agent >=1.2.0; the agent's first-class
          # version field is what the generator gates delivery on.
          version: "1.2.0",
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
          # The otel-collector config schema sets additionalProperties:false with
          # no required fields, so an empty params object is the minimal valid
          # one-touch config.
          params: %{}
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, "default")

    assert [addon] = config.addons
    assert addon.addon_id == "otel-collector"
    assert addon.enabled == true
    assert addon.delivery == :pushed_artifact
    assert addon.supervision == :agent_sidecar
    assert addon.capabilities == ["otlp-relay:v1", "native-telemetry:v1"]
    assert addon.os_capabilities == []
    assert addon.artifact_object_key == object_key
    assert addon.artifact_sha256 == sha
    assert addon.artifact_signature == signature
    assert addon.target_os == "linux"
    assert addon.target_arch == "amd64"

    proto = AgentConfigGenerator.to_proto_response(config)
    assert [proto_addon] = proto.addons
    assert proto_addon.addon_id == "otel-collector"
    assert proto_addon.delivery == "pushed_artifact"
    assert proto_addon.supervision == "agent_sidecar"
    assert proto_addon.artifact_object_key == object_key
    assert proto_addon.artifact_sha256 == sha
    assert proto_addon.artifact_signature == signature
  end

  test "stages the manifest version without configured artifacts", %{
    actor: actor,
    unique_id: unique_id
  } do
    version = "0.9.#{unique_id}"

    assert :ok = OtelCollectorAddonPackageSeeder.seed_defaults(version: version, artifacts: %{})

    {:ok, package} = read_package(version, actor)
    assert package.status == :staged
    assert package.artifacts == %{}
    assert package.source_oci_ref == nil
    assert package.source_oci_digest == nil
    assert package.capabilities == ["otlp-relay:v1", "native-telemetry:v1"]
    assert package.config_schema["title"] == "OTEL Collector Add-on Configuration"
  end

  defp read_package(version, actor) do
    AddonPackage
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(addon_id == "otel-collector" and version == ^version)
    |> Ash.read_one(actor: actor)
  end
end
