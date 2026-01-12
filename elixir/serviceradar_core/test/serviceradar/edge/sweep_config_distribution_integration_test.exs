defmodule ServiceRadar.Edge.SweepConfigDistributionIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.AgentConfig.ConfigServer
  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.SweepJobs.{SweepGroup, SweepProfile}
  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    %{tenant_id: tenant_id, tenant_slug: tenant_slug} =
      TestSupport.create_tenant_schema!("sweep-config")

    on_exit(fn ->
      TestSupport.drop_tenant_schema!(tenant_slug)
    end)

    actor = %{
      id: Ash.UUID.generate(),
      email: "sweep-config@serviceradar.local",
      role: :admin,
      tenant_id: tenant_id
    }

    agent_id = "agent-#{System.unique_integer([:positive])}"

    {:ok, tenant_id: tenant_id, actor: actor, agent_id: agent_id}
  end

  test "includes sweep config in agent payload", %{
    tenant_id: tenant_id,
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = System.unique_integer([:positive])
    device_uid = "device-#{unique_id}"
    device_ip = "10.0.1.10"

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: device_uid,
          ip: device_ip,
          tags: %{"env" => "prod"}
        }, actor: actor, tenant: tenant_id, authorize?: false)
      |> Ash.create()

    {:ok, profile} =
      SweepProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Profile #{unique_id}",
          ports: [22, 80],
          sweep_modes: ["icmp", "tcp"],
          concurrency: 25,
          timeout: "4s"
        }, actor: actor, tenant: tenant_id, authorize?: false)
      |> Ash.create()

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Group #{unique_id}",
          partition: "default",
          interval: "15m",
          profile_id: profile.id,
          target_criteria: %{"tags" => %{"has_any" => ["env=prod"]}},
          static_targets: ["10.0.2.0/24"]
        }, actor: actor, tenant: tenant_id, authorize?: false)
      |> Ash.create()

    {:ok, entry} = ConfigServer.get_config(tenant_id, :sweep, "default", agent_id)

    assert is_map(entry.config)
    assert is_binary(entry.config["config_hash"])

    [compiled_group] = entry.config["groups"]
    assert compiled_group["sweep_group_id"] == group.id
    assert device_ip in compiled_group["targets"]
    assert "10.0.2.0/24" in compiled_group["targets"]
    assert compiled_group["ports"] == profile.ports
    assert compiled_group["modes"] == profile.sweep_modes

    {:ok, agent_config} = AgentConfigGenerator.generate_config(agent_id, tenant_id)
    payload = Jason.decode!(agent_config.config_json)
    sweep_payload = payload["sweep"]

    assert sweep_payload["config_hash"] == entry.config["config_hash"]
    assert length(sweep_payload["groups"]) == 1
  end
end
