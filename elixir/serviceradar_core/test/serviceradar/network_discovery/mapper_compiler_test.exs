defmodule ServiceRadar.AgentConfig.Compilers.MapperCompilerTest do
  @moduledoc """
  Integration tests for MapperCompiler credential resolution.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.MapperCompiler
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.NetworkDiscovery.MapperSeed
  alias ServiceRadar.SNMPProfiles.SNMPProfile

  @tag :integration
  setup do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  @tag :integration
  test "uses profile credentials for mapper discovery jobs" do
    actor = SystemActor.system(:test)
    device_uid = "sr:" <> Ash.UUID.generate()

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: device_uid,
          hostname: "mapper-target",
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
          name: "Default SNMP",
          enabled: true,
          target_query: "in:devices hostname:mapper-target",
          priority: 10,
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
          name: "Mapper Job",
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

    assert [compiled_job] = config["scheduled_jobs"]
    assert compiled_job["credentials"]["version"] == "v2c"
    assert compiled_job["credentials"]["community"] == "public"
  end

  @tag :integration
  test "falls back to default SNMP profile credentials when device uid is missing" do
    actor = SystemActor.system(:test)

    {:ok, _profile} =
      SNMPProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Mapper Default",
          enabled: true,
          is_default: true,
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
          name: "Mapper Job Default",
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

    assert [compiled_job] = config["scheduled_jobs"]
    assert compiled_job["credentials"]["version"] == "v2c"
    assert compiled_job["credentials"]["community"] == "public"
  end
end
