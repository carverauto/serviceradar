defmodule ServiceRadar.Plugins.WorkloadIdentityAddonPackageSeederTest do
  @moduledoc """
  DB-backed coverage for the workload identity native add-on control-plane seed.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.WorkloadIdentityAddonPackageSeeder

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

  test "seeds approved workload identity package and compiles assignment as systemd service",
       %{actor: actor, unique_id: unique_id} do
    version = "0.1.#{unique_id}"
    sha = String.duplicate("b", 64)
    signature = "sig-#{unique_id}"

    object_key =
      "native-addons/workload-identity/#{version}/linux/amd64/#{String.duplicate("a", 64)}.tar.gz"

    artifacts = %{
      "linux/amd64" => %{
        "object_key" => object_key,
        "sha256" => sha,
        "signature" => signature
      }
    }

    assert :ok =
             WorkloadIdentityAddonPackageSeeder.seed_defaults(
               version: version,
               artifacts: artifacts,
               source_oci_ref:
                 "registry.carverauto.dev/serviceradar/serviceradar-addon-workload-identity:sha-test",
               source_oci_digest: "sha256:#{String.duplicate("e", 64)}",
               source_release_tag: "sha-test"
             )

    {:ok, package} = read_package(version, actor)
    assert package.status == :approved
    assert package.addon_id == "workload-identity"
    assert package.delivery == :pushed_artifact
    assert package.supervision == :systemd_service
    assert package.binary == "serviceradar-workload-identity"
    assert package.capabilities == ["workload-identity", "container-inventory"]
    assert package.approved_capabilities == ["workload-identity", "container-inventory"]
    assert package.requires["run_as"] == "root"
    assert package.requires["os_capabilities"] == []
    assert package.config_schema["title"] == "Workload Identity Configuration"
    assert package.artifacts["linux/amd64"]["object_key"] == object_key

    agent_uid = "workload-identity-agent-#{unique_id}"

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(
        :register_connected,
        %{
          uid: agent_uid,
          name: "Workload Identity Test Agent #{unique_id}",
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
          params: %{"enabled" => true, "refresh_interval_s" => 60}
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, "default")

    assert [addon] = config.addons
    assert addon.addon_id == "workload-identity"
    assert addon.enabled == true
    assert addon.delivery == :pushed_artifact
    assert addon.supervision == :systemd_service
    assert addon.capabilities == ["workload-identity", "container-inventory"]
    assert addon.os_capabilities == []
    assert addon.artifact_object_key == object_key
    assert addon.artifact_sha256 == sha
    assert addon.artifact_signature == signature
    assert addon.params["refresh_interval_s"] == 60
  end

  test "stages manifest version without configured artifacts", %{
    actor: actor,
    unique_id: unique_id
  } do
    version = "0.9.#{unique_id}"

    assert :ok =
             WorkloadIdentityAddonPackageSeeder.seed_defaults(version: version, artifacts: %{})

    {:ok, package} = read_package(version, actor)
    assert package.status == :staged
    assert package.artifacts == %{}
    assert package.capabilities == ["workload-identity", "container-inventory"]
    assert package.config_schema["title"] == "Workload Identity Configuration"
  end

  defp read_package(version, actor) do
    AddonPackage
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(addon_id == "workload-identity" and version == ^version)
    |> Ash.read_one(actor: actor)
  end
end
