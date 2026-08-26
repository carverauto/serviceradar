defmodule ServiceRadar.Edge.SweepConfigDistributionIntegrationTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.AgentConfig.ConfigServer
  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepProfile
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = %{
      id: Ash.UUID.generate(),
      email: "sweep-config@serviceradar.local",
      role: :admin
    }

    agent_id = "agent-#{System.unique_integer([:positive])}"

    {:ok, actor: actor, agent_id: agent_id}
  end

  test "includes sweep config in agent payload", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = System.unique_integer([:positive])
    device_uid = "device-#{unique_id}"
    device_ip = "10.0.#{rem(unique_id, 200) + 20}.#{rem(div(unique_id, 200), 200) + 20}"

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: device_uid,
          ip: device_ip,
          tags: %{"env" => "prod"}
        },
        actor: actor
      )
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
        },
        actor: actor
      )
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
          target_query: "in:devices tags.env:prod",
          static_targets: ["10.0.2.0/24"]
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, entry} = ConfigServer.get_config(:sweep, "default", agent_id)

    assert is_map(entry.config)
    assert is_binary(entry.config["config_hash"])

    compiled_group = Enum.find(entry.config["groups"], &(&1["sweep_group_id"] == group.id))
    assert is_map(compiled_group)
    assert compiled_group["sweep_group_id"] == group.id
    assert device_ip in device_target_networks(compiled_group)
    assert "10.0.2.0/24" in compiled_group["targets"]
    assert compiled_group["ports"] == profile.ports
    assert compiled_group["modes"] == profile.sweep_modes

    {:ok, agent_config} = AgentConfigGenerator.generate_config(agent_id, "default")
    payload = Jason.decode!(agent_config.config_json)
    sweep_payload = payload["sweep"]
    generated_group = Enum.find(sweep_payload["groups"], &(&1["sweep_group_id"] == group.id))

    assert sweep_payload["config_hash"] == entry.config["config_hash"]
    assert is_map(generated_group)
  end

  test "inherits profile ports when group ports override is empty", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = System.unique_integer([:positive])
    partition = "ports-inherit-#{unique_id}"

    {:ok, profile} =
      SweepProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Profile inherit #{unique_id}",
          ports: [80, 443],
          sweep_modes: ["icmp", "tcp"],
          concurrency: 10,
          timeout: "2s"
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, _group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Group inherit #{unique_id}",
          partition: partition,
          interval: "15m",
          profile_id: profile.id,
          ports: [],
          static_targets: ["10.0.9.0/24"]
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, entry} = ConfigServer.get_config(:sweep, partition, agent_id)

    [compiled_group] = entry.config["groups"]
    assert compiled_group["ports"] == profile.ports
  end

  test "drops tcp modes when no ports are configured", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = System.unique_integer([:positive])
    partition = "ports-empty-#{unique_id}"

    {:ok, _group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Group no ports #{unique_id}",
          partition: partition,
          interval: "15m",
          sweep_modes: ["icmp", "tcp"],
          ports: [],
          static_targets: ["10.0.10.0/24"]
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, entry} = ConfigServer.get_config(:sweep, partition, agent_id)

    [compiled_group] = entry.config["groups"]
    refute "tcp" in compiled_group["modes"]
  end

  test "compiles an isolation group onto the assigned agent in a different partition", %{
    actor: actor,
    agent_id: agent_id
  } do
    unique_id = System.unique_integer([:positive])
    agent_partition = "default"
    device_partition = "rids-#{unique_id}"
    device_ip = "10.1.#{rem(unique_id, 200) + 20}.#{rem(div(unique_id, 200), 200) + 20}"

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: "device-rids-#{unique_id}",
          ip: device_ip,
          partition: device_partition
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, assigned_group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Isolation assigned #{unique_id}",
          partition: device_partition,
          agent_id: agent_id,
          interval: "2m",
          sweep_modes: ["icmp"],
          static_targets: [device_ip]
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, _unassigned_group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Isolation unassigned #{unique_id}",
          partition: device_partition,
          interval: "2m",
          sweep_modes: ["icmp"],
          static_targets: ["10.255.255.1"]
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, entry} = ConfigServer.get_config(:sweep, agent_partition, agent_id)

    compiled_ids = Enum.map(entry.config["groups"] || [], & &1["sweep_group_id"])
    assert assigned_group.id in compiled_ids

    refute Enum.any?(
             entry.config["groups"] || [],
             &(&1["name"] == "Isolation unassigned #{unique_id}")
           )

    compiled = Enum.find(entry.config["groups"], &(&1["sweep_group_id"] == assigned_group.id))
    assert device_ip in compiled["targets"]
  end

  test "an All-agents group is compiled onto every agent in the partition", %{
    actor: actor
  } do
    unique_id = System.unique_integer([:positive])
    agent_a = "agent-a-#{unique_id}"
    agent_b = "agent-b-#{unique_id}"
    target = "10.2.#{rem(unique_id, 200) + 20}.#{rem(div(unique_id, 200), 200) + 20}"

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "All agents #{unique_id}",
          partition: "default",
          agent_id: "",
          interval: "2m",
          sweep_modes: ["icmp"],
          static_targets: [target]
        },
        actor: actor
      )
      |> Ash.create()

    assert is_nil(group.agent_id)

    {:ok, pinned} =
      group
      |> Ash.Changeset.for_update(:update, %{agent_id: agent_a}, actor: actor)
      |> Ash.update()

    assert pinned.agent_id == agent_a

    {:ok, group} =
      pinned
      |> Ash.Changeset.for_update(:update, %{agent_id: ""}, actor: actor)
      |> Ash.update()

    assert is_nil(group.agent_id)

    ConfigServer.invalidate(:sweep)

    {:ok, entry_a} = ConfigServer.get_config(:sweep, "default", agent_a)
    {:ok, entry_b} = ConfigServer.get_config(:sweep, "default", agent_b)

    ids_a = Enum.map(entry_a.config["groups"] || [], & &1["sweep_group_id"])
    ids_b = Enum.map(entry_b.config["groups"] || [], & &1["sweep_group_id"])

    assert group.id in ids_a
    assert group.id in ids_b

    compiled_a = Enum.find(entry_a.config["groups"], &(&1["sweep_group_id"] == group.id))
    compiled_b = Enum.find(entry_b.config["groups"], &(&1["sweep_group_id"] == group.id))
    assert target in compiled_a["targets"]
    assert target in compiled_b["targets"]
  end

  defp device_target_networks(compiled_group) do
    Enum.map(compiled_group["device_targets"] || [], & &1["network"])
  end
end
