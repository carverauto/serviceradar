defmodule ServiceRadar.AgentConfig.Compilers.MapperCompilerTest do
  @moduledoc """
  Integration tests for MapperCompiler credential resolution.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.MapperCompiler
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.NetworkDiscovery.MapperMikrotikController
  alias ServiceRadar.NetworkDiscovery.MapperSeed
  alias ServiceRadar.NetworkDiscovery.MapperUnifiController
  alias ServiceRadar.SNMPProfiles.CredentialResolver
  alias ServiceRadar.SNMPProfiles.SNMPProfile

  @tag :integration
  setup do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  @tag :integration
  test "uses profile credentials for mapper discovery jobs" do
    actor = SystemActor.system(:test)
    unique_id = System.unique_integer([:positive])
    device_uid = "sr:" <> Ash.UUID.generate()
    hostname = "mapper-target-#{unique_id}"
    job_name = "Mapper Job #{unique_id}"

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: device_uid,
          hostname: hostname,
          type_id: 10,
          created_time: DateTime.utc_now(),
          modified_time: DateTime.utc_now()
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, _profile} =
      SNMPProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Default SNMP #{unique_id}",
          enabled: true,
          target_query: ~s(in:devices hostname:"#{hostname}"),
          priority: 1_000_000 + unique_id,
          community: "public"
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, job} =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: job_name,
          discovery_mode: :snmp,
          discovery_type: :full
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, _seed} =
      MapperSeed
      |> Ash.Changeset.for_create(
        :create,
        %{mapper_job_id: job.id, seed: "192.168.1.0/24"},
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, config} = MapperCompiler.compile("default", nil, actor: actor, device_uid: device_uid)

    compiled_job =
      Enum.find(config["scheduled_jobs"], fn scheduled_job ->
        scheduled_job["name"] == job_name
      end)

    assert compiled_job != nil
    assert compiled_job["credentials"]["version"] == "v2c"
    assert compiled_job["credentials"]["community"] == "public"
  end

  @tag :integration
  test "falls back to default SNMP profile credentials when device uid is missing" do
    actor = SystemActor.system(:test)
    unique_id = System.unique_integer([:positive])
    job_name = "Mapper Job Default #{unique_id}"

    {:ok, job} =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: job_name,
          discovery_mode: :snmp,
          discovery_type: :full
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, _seed} =
      MapperSeed
      |> Ash.Changeset.for_create(
        :create,
        %{mapper_job_id: job.id, seed: "192.168.10.1"},
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, config} = MapperCompiler.compile("default", nil, actor: actor)

    compiled_job =
      Enum.find(config["scheduled_jobs"], fn scheduled_job ->
        scheduled_job["name"] == job_name
      end)

    assert compiled_job != nil
    assert compiled_job["credentials"]["version"] == "v2c"

    case CredentialResolver.resolve_default(actor) do
      {:ok, %{credential: %{community: community}}}
      when is_binary(community) and community != "" ->
        assert compiled_job["credentials"]["community"] == community

      _ ->
        refute Map.has_key?(compiled_job["credentials"], "community")
    end
  end

  @tag :integration
  test "compiles mikrotik controllers into mapper config and job selectors" do
    actor = SystemActor.system(:test)
    unique_id = System.unique_integer([:positive])
    job_name = "Mapper Job MikroTik #{unique_id}"
    controller_name = "chr-demo-#{unique_id}"

    {:ok, job} =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: job_name,
          discovery_mode: :api,
          discovery_type: :full
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, _controller} =
      MapperMikrotikController
      |> Ash.Changeset.for_create(
        :create,
        %{
          mapper_job_id: job.id,
          name: controller_name,
          base_url: "https://192.168.88.1",
          username: "admin",
          password: "secret"
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, config} = MapperCompiler.compile("default", nil, actor: actor)

    assert Enum.any?(config["mikrotik_apis"], fn controller ->
             controller["name"] == controller_name and
               controller["base_url"] == "https://192.168.88.1/rest"
           end)

    compiled_job =
      Enum.find(config["scheduled_jobs"], fn scheduled_job ->
        scheduled_job["name"] == job_name
      end)

    assert compiled_job != nil
    assert compiled_job["options"]["mikrotik_api_names"] == controller_name
    assert compiled_job["options"]["mikrotik_api_urls"] == "https://192.168.88.1/rest"
  end

  @tag :integration
  test "normalizes nil API secrets to empty strings in mapper config" do
    actor = SystemActor.system(:test)
    unique_id = System.unique_integer([:positive])
    job_name = "Mapper Job API Nil Secret #{unique_id}"

    {:ok, job} =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: job_name,
          discovery_mode: :api,
          discovery_type: :full
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, _mikrotik_controller} =
      MapperMikrotikController
      |> Ash.Changeset.for_create(
        :create,
        %{
          mapper_job_id: job.id,
          name: "chr-demo-#{unique_id}",
          base_url: "https://192.168.88.1",
          username: "admin",
          password: nil
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, _unifi_controller} =
      MapperUnifiController
      |> Ash.Changeset.for_create(
        :create,
        %{
          mapper_job_id: job.id,
          name: "unifi-demo-#{unique_id}",
          base_url: "https://192.168.10.1",
          api_key: nil
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, config} = MapperCompiler.compile("default", nil, actor: actor)

    assert Enum.any?(config["mikrotik_apis"], fn controller ->
             controller["name"] == "chr-demo-#{unique_id}" and controller["password"] == ""
           end)

    assert Enum.any?(config["unifi_apis"], fn controller ->
             controller["name"] == "unifi-demo-#{unique_id}" and controller["api_key"] == ""
           end)
  end
end
