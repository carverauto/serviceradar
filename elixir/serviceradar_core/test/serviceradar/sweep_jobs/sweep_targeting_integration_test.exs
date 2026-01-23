defmodule ServiceRadar.SweepJobs.SweepTargetingIntegrationTest do
  @moduledoc """
  Integration tests for sweep targeting rules end-to-end.

  These tests verify that:
  1. Targeting SRQL query is correctly saved to the database
  2. SweepCompiler correctly resolves targets from SRQL
  3. Agents receive the correct sweep config based on partition
  4. Config changes trigger cache invalidation
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.AgentConfig.ConfigServer
  alias ServiceRadar.AgentRegistry
  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.SweepJobs.{SweepGroup, SweepProfile}
  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = %{
      id: Ash.UUID.generate(),
      email: "sweep-targeting-test@serviceradar.local",
      role: :admin
    }

    unique_id = System.unique_integer([:positive])

    {:ok, actor: actor, unique_id: unique_id}
  end

  describe "target_query persistence" do
    test "CIDR targeting query is saved and normalized", %{actor: actor, unique_id: unique_id} do
      {:ok, group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "CIDR Group #{unique_id}",
            partition: "default",
            interval: "15m",
            target_query: "ip:10.0.0.0/8"
          }, actor: actor)
        |> Ash.create()

      assert group.target_query == "in:devices ip:10.0.0.0/8"

      {:ok, reloaded} = Ash.get(SweepGroup, group.id, actor: actor)
      assert reloaded.target_query == "in:devices ip:10.0.0.0/8"
    end

    test "tag targeting query is saved and loaded correctly", %{
      actor: actor,
      unique_id: unique_id
    } do
      {:ok, group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Tag Group #{unique_id}",
            partition: "default",
            interval: "15m",
            target_query: "in:devices tags.env:prod"
          }, actor: actor)
        |> Ash.create()

      assert group.target_query == "in:devices tags.env:prod"

      {:ok, reloaded} = Ash.get(SweepGroup, group.id, actor: actor)
      assert reloaded.target_query == "in:devices tags.env:prod"
    end

    test "empty target_query is stored as nil", %{actor: actor, unique_id: unique_id} do
      {:ok, group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Empty Query Group #{unique_id}",
            partition: "default",
            interval: "15m",
            target_query: ""
          }, actor: actor)
        |> Ash.create()

      assert group.target_query == nil
    end
  end

  describe "sweep compiler with SRQL targeting" do
    test "compiles sweep group with CIDR query and matching devices", %{
      actor: actor,
      unique_id: unique_id
    } do
      # Create devices - some matching, some not
      {:ok, matching_device1} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: "device-match-1-#{unique_id}",
            ip: "10.0.1.100",
            hostname: "server1"
          }, actor: actor)
        |> Ash.create()

      {:ok, matching_device2} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: "device-match-2-#{unique_id}",
            ip: "10.0.2.50",
            hostname: "server2"
          }, actor: actor)
        |> Ash.create()

      {:ok, _non_matching_device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: "device-nomatch-#{unique_id}",
            ip: "192.168.1.100",
            hostname: "external"
          }, actor: actor)
        |> Ash.create()

      # Create sweep group with CIDR query
      {:ok, _group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "CIDR Compile Group #{unique_id}",
            partition: "default",
            interval: "15m",
            target_query: "in:devices ip:10.0.0.0/8",
            enabled: true
          }, actor: actor)
        |> Ash.create()

      # Get compiled config
      {:ok, entry} = ConfigServer.get_config(:sweep, "default", nil)

      assert is_map(entry.config)
      assert not Enum.empty?(entry.config["groups"])

      # Find our group
      compiled_group =
        Enum.find(entry.config["groups"], fn g ->
          g["name"] == "CIDR Compile Group #{unique_id}"
        end)

      assert compiled_group != nil
      assert matching_device1.ip in compiled_group["targets"]
      assert matching_device2.ip in compiled_group["targets"]
      refute "192.168.1.100" in compiled_group["targets"]
    end

    test "compiles sweep group with tag query and matching devices", %{
      actor: actor,
      unique_id: unique_id
    } do
      # Create devices with tags
      {:ok, prod_device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: "device-prod-#{unique_id}",
            ip: "10.0.1.1",
            hostname: "prod-server",
            tags: %{"env" => "prod", "tier" => "1"}
          }, actor: actor)
        |> Ash.create()

      {:ok, _dev_device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: "device-dev-#{unique_id}",
            ip: "10.0.2.1",
            hostname: "dev-server",
            tags: %{"env" => "dev"}
          }, actor: actor)
        |> Ash.create()

      # Create sweep group targeting prod
      {:ok, _group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Tag Compile Group #{unique_id}",
            partition: "default",
            interval: "15m",
            target_query: "in:devices tags.env:prod",
            enabled: true
          }, actor: actor)
        |> Ash.create()

      {:ok, entry} = ConfigServer.get_config(:sweep, "default", nil)

      compiled_group =
        Enum.find(entry.config["groups"], fn g ->
          g["name"] == "Tag Compile Group #{unique_id}"
        end)

      assert compiled_group != nil
      assert prod_device.ip in compiled_group["targets"]
      # Dev device should not be in targets (different tag value)
    end

    test "compiles sweep group combining SRQL with static_targets", %{
      actor: actor,
      unique_id: unique_id
    } do
      {:ok, device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: "device-combined-#{unique_id}",
            ip: "10.0.1.50",
            hostname: "combined-server"
          }, actor: actor)
        |> Ash.create()

      static_targets = ["192.168.100.0/24", "172.16.0.1"]

      {:ok, _group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Combined Targets Group #{unique_id}",
            partition: "default",
            interval: "15m",
            target_query: "in:devices ip:10.0.0.0/8",
            static_targets: static_targets,
            enabled: true
          }, actor: actor)
        |> Ash.create()

      {:ok, entry} = ConfigServer.get_config(:sweep, "default", nil)

      compiled_group =
        Enum.find(entry.config["groups"], fn g ->
          g["name"] == "Combined Targets Group #{unique_id}"
        end)

      assert compiled_group != nil
      # Should have both criteria-matched and static targets
      assert device.ip in compiled_group["targets"]
      assert "192.168.100.0/24" in compiled_group["targets"]
      assert "172.16.0.1" in compiled_group["targets"]
    end

    test "empty SRQL query with static_targets only includes static_targets", %{
      actor: actor,
      unique_id: unique_id
    } do
      static_targets = ["10.0.0.0/24", "192.168.1.1"]

      {:ok, _group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Static Only Group #{unique_id}",
            partition: "default",
            interval: "15m",
            target_query: nil,
            static_targets: static_targets,
            enabled: true
          }, actor: actor)
        |> Ash.create()

      {:ok, entry} = ConfigServer.get_config(:sweep, "default", nil)

      compiled_group =
        Enum.find(entry.config["groups"], fn g ->
          g["name"] == "Static Only Group #{unique_id}"
        end)

      assert compiled_group != nil
      assert "10.0.0.0/24" in compiled_group["targets"]
      assert "192.168.1.1" in compiled_group["targets"]
    end
  end

  describe "partition-based sweep group filtering" do
    test "agent receives only sweep groups matching its partition", %{
      actor: actor,
      unique_id: unique_id
    } do
      # Create groups in different partitions
      {:ok, _default_group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Default Partition Group #{unique_id}",
            partition: "default",
            interval: "15m",
            static_targets: ["10.0.0.1"],
            enabled: true
          }, actor: actor)
        |> Ash.create()

      {:ok, _datacenter_group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Datacenter Partition Group #{unique_id}",
            partition: "datacenter-1",
            interval: "15m",
            static_targets: ["192.168.1.1"],
            enabled: true
          }, actor: actor)
        |> Ash.create()

      # Get config for default partition
      {:ok, default_entry} = ConfigServer.get_config(:sweep, "default", nil)

      default_group_names = Enum.map(default_entry.config["groups"], & &1["name"])
      assert "Default Partition Group #{unique_id}" in default_group_names
      refute "Datacenter Partition Group #{unique_id}" in default_group_names

      # Get config for datacenter-1 partition
      {:ok, dc_entry} = ConfigServer.get_config(:sweep, "datacenter-1", nil)

      dc_group_names = Enum.map(dc_entry.config["groups"], & &1["name"])
      assert "Datacenter Partition Group #{unique_id}" in dc_group_names
      refute "Default Partition Group #{unique_id}" in dc_group_names
    end

    test "agent-specific groups are included when agent_id matches", %{
      actor: actor,
      unique_id: unique_id
    } do
      agent_id = "agent-specific-#{unique_id}"

      # Create agent-specific group
      {:ok, _specific_group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Agent Specific Group #{unique_id}",
            partition: "default",
            agent_id: agent_id,
            interval: "15m",
            static_targets: ["10.0.0.99"],
            enabled: true
          }, actor: actor)
        |> Ash.create()

      # Create partition-wide group (nil agent_id)
      {:ok, _partition_group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Partition Wide Group #{unique_id}",
            partition: "default",
            agent_id: nil,
            interval: "15m",
            static_targets: ["10.0.0.1"],
            enabled: true
          }, actor: actor)
        |> Ash.create()

      # Get config for specific agent
      {:ok, entry} = ConfigServer.get_config(:sweep, "default", agent_id)

      group_names = Enum.map(entry.config["groups"], & &1["name"])

      # Should include both agent-specific and partition-wide groups
      assert "Agent Specific Group #{unique_id}" in group_names
      assert "Partition Wide Group #{unique_id}" in group_names
    end

    test "agent-specific groups are excluded for other agents", %{
      actor: actor,
      unique_id: unique_id
    } do
      agent_id = "agent-owner-#{unique_id}"
      other_agent_id = "agent-other-#{unique_id}"

      {:ok, _specific_group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Owner Only Group #{unique_id}",
            partition: "default",
            agent_id: agent_id,
            interval: "15m",
            static_targets: ["10.0.0.99"],
            enabled: true
          }, actor: actor)
        |> Ash.create()

      # Get config for different agent
      {:ok, entry} = ConfigServer.get_config(:sweep, "default", other_agent_id)

      group_names = Enum.map(entry.config["groups"], & &1["name"])

      # Should NOT include group assigned to different agent
      refute "Owner Only Group #{unique_id}" in group_names
    end
  end

  describe "sweep profile integration" do
    test "sweep group inherits settings from profile", %{actor: actor, unique_id: unique_id} do
      # Create profile with specific settings
      {:ok, profile} =
        SweepProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Test Profile #{unique_id}",
            ports: [22, 80, 443, 8080],
            sweep_modes: ["icmp", "tcp"],
            concurrency: 100,
            timeout: "5s"
          }, actor: actor)
        |> Ash.create()

      # Create group using the profile
      {:ok, _group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Profile Group #{unique_id}",
            partition: "default",
            interval: "30m",
            profile_id: profile.id,
            static_targets: ["10.0.0.0/24"],
            enabled: true
          }, actor: actor)
        |> Ash.create()

      {:ok, entry} = ConfigServer.get_config(:sweep, "default", nil)

      compiled_group =
        Enum.find(entry.config["groups"], fn g ->
          g["name"] == "Profile Group #{unique_id}"
        end)

      assert compiled_group != nil
      assert compiled_group["ports"] == [22, 80, 443, 8080]
      assert compiled_group["modes"] == ["icmp", "tcp"]
      assert compiled_group["settings"]["concurrency"] == 100
      assert compiled_group["settings"]["timeout"] == "5s"
    end
  end

  describe "config change detection" do
    test "config hash changes when sweep group is updated", %{actor: actor, unique_id: unique_id} do
      {:ok, group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Hash Change Group #{unique_id}",
            partition: "default",
            interval: "15m",
            static_targets: ["10.0.0.1"],
            enabled: true
          }, actor: actor)
        |> Ash.create()

      {:ok, entry1} = ConfigServer.get_config(:sweep, "default", nil)
      hash1 = entry1.config["config_hash"]

      # Invalidate cache and update group
      ConfigServer.invalidate(:sweep)

      {:ok, _updated} =
        group
        |> Ash.Changeset.for_update(:update, %{
          static_targets: ["10.0.0.1", "10.0.0.2"]
        })
        |> Ash.update(actor: actor)

      {:ok, entry2} = ConfigServer.get_config(:sweep, "default", nil)
      hash2 = entry2.config["config_hash"]

      # Hash should be different after update
      refute hash1 == hash2
    end
  end
end
