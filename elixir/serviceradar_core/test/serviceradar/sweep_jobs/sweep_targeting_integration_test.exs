defmodule ServiceRadar.SweepJobs.SweepTargetingIntegrationTest do
  @moduledoc """
  Integration tests for sweep targeting rules end-to-end.

  These tests verify that:
  1. Targeting SRQL query is correctly saved to the database
  2. SweepCompiler correctly resolves targets from SRQL
  3. Agents receive the correct sweep config based on partition
  4. Config changes trigger cache invalidation
  """
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.AgentConfig.Compilers.SweepCompiler
  alias ServiceRadar.AgentConfig.ConfigCache
  alias ServiceRadar.AgentConfig.ConfigServer
  alias ServiceRadar.AgentConfig.DependencyDiagnostics
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Repo
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
          },
          actor: actor
        )
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
          },
          actor: actor
        )
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
          },
          actor: actor
        )
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
            ip: unique_device_ip(unique_id, 1),
            hostname: "server1"
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, matching_device2} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: "device-match-2-#{unique_id}",
            ip: unique_device_ip(unique_id, 2),
            hostname: "server2"
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, _non_matching_device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: "device-nomatch-#{unique_id}",
            ip: non_matching_device_ip(unique_id, 1),
            hostname: "external"
          },
          actor: actor
        )
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
          },
          actor: actor
        )
        |> Ash.create()

      ConfigServer.invalidate(:sweep)

      # Get compiled config
      {:ok, entry} = ConfigServer.get_config(:sweep, "default", nil)

      assert is_map(entry.config)
      refute Enum.empty?(entry.config["groups"])

      # Find our group
      compiled_group =
        Enum.find(entry.config["groups"], fn g ->
          g["name"] == "CIDR Compile Group #{unique_id}"
        end)

      assert compiled_group
      device_targets = device_target_networks(compiled_group)
      assert matching_device1.ip in device_targets
      assert matching_device2.ip in device_targets
      refute non_matching_device_ip(unique_id, 1) in device_targets
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
            ip: unique_device_ip(unique_id, 3),
            hostname: "prod-server",
            tags: %{"env" => "prod", "tier" => "1"}
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, _dev_device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: "device-dev-#{unique_id}",
            ip: unique_device_ip(unique_id, 4),
            hostname: "dev-server",
            tags: %{"env" => "dev"}
          },
          actor: actor
        )
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
          },
          actor: actor
        )
        |> Ash.create()

      ConfigServer.invalidate(:sweep)

      {:ok, entry} = ConfigServer.get_config(:sweep, "default", nil)

      compiled_group =
        Enum.find(entry.config["groups"], fn g ->
          g["name"] == "Tag Compile Group #{unique_id}"
        end)

      assert compiled_group
      assert prod_device.ip in device_target_networks(compiled_group)
      # Dev device should not be in targets (different tag value)
    end

    test "does not enable TCP when group has no profile and no ports", %{
      actor: actor,
      unique_id: unique_id
    } do
      partition = "icmp-only-#{unique_id}"

      {:ok, group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "No Profile #{unique_id}",
            partition: partition,
            interval: "1h",
            static_targets: ["192.168.1.0/24"],
            enabled: true
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, config} = SweepCompiler.compile(partition, nil, actor: actor)

      compiled_group = Enum.find(config["groups"], &(&1["id"] == group.id))

      assert compiled_group
      assert compiled_group["ports"] == []
      assert compiled_group["modes"] == ["icmp"]
    end

    test "inherits scanner profile ports and TCP mode", %{
      actor: actor,
      unique_id: unique_id
    } do
      partition = "profile-ports-#{unique_id}"

      {:ok, profile} =
        SweepProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Profile #{unique_id}",
            ports: [22, 80, 443, 8080],
            sweep_modes: ["icmp", "tcp", "arp"]
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "With Profile #{unique_id}",
            partition: partition,
            interval: "1h",
            static_targets: ["192.168.1.0/24"],
            profile_id: profile.id,
            enabled: true
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, config} = SweepCompiler.compile(partition, nil, actor: actor)

      compiled_group = Enum.find(config["groups"], &(&1["id"] == group.id))

      assert compiled_group
      assert compiled_group["ports"] == [22, 80, 443, 8080]
      assert compiled_group["modes"] == ["icmp", "tcp"]
    end

    test "skips comma-separated device IP fields when compiling sweep targets", %{
      actor: actor,
      unique_id: unique_id
    } do
      first_ip = unique_device_ip(unique_id, 11)
      second_ip = unique_device_ip(unique_id, 12)
      hostname = "multi-ip-device-#{unique_id}"

      {:ok, _device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: "device-multi-ip-#{unique_id}",
            ip: "#{first_ip}, #{second_ip}",
            hostname: hostname
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, _group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Multi IP Compile Group #{unique_id}",
            partition: "default",
            interval: "15m",
            target_query: ~s(in:devices hostname:"#{hostname}"),
            enabled: true
          },
          actor: actor
        )
        |> Ash.create()

      ConfigServer.invalidate(:sweep)

      {:ok, entry} = ConfigServer.get_config(:sweep, "default", nil)

      compiled_group =
        Enum.find(entry.config["groups"], fn g ->
          g["name"] == "Multi IP Compile Group #{unique_id}"
        end)

      assert compiled_group
      device_targets = device_target_networks(compiled_group)
      refute first_ip in device_targets
      refute second_ip in device_targets
      refute "#{first_ip}, #{second_ip}" in device_targets
    end

    test "ignores integration network blacklist settings when compiling sweep targets", %{
      actor: actor,
      unique_id: unique_id
    } do
      included_ip = unique_device_ip(unique_id, 13)
      source_agent_id = "blacklist-source-agent-#{unique_id}"

      {:ok, _agent} =
        Agent
        |> Ash.Changeset.for_create(:register_connected, %{uid: source_agent_id}, actor: actor)
        |> Ash.create(actor: actor)

      {:ok, _armis_source} =
        IntegrationSource
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Armis Source #{unique_id}",
            source_type: :armis,
            endpoint: "https://armis.example.invalid",
            agent_id: source_agent_id,
            network_blacklist: ["10.0.0.0/8", "192.168.0.0/16"]
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, _device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: "device-blacklist-isolated-#{unique_id}",
            ip: included_ip,
            hostname: "blacklist-isolated-#{unique_id}"
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, _group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Blacklist Isolation Group #{unique_id}",
            partition: "default",
            interval: "15m",
            target_query: ~s(in:devices hostname:"blacklist-isolated-#{unique_id}"),
            enabled: true
          },
          actor: actor
        )
        |> Ash.create()

      ConfigServer.invalidate(:sweep)

      {:ok, entry} = ConfigServer.get_config(:sweep, "default", nil)

      compiled_group =
        Enum.find(entry.config["groups"], fn g ->
          g["name"] == "Blacklist Isolation Group #{unique_id}"
        end)

      assert compiled_group
      assert included_ip in device_target_networks(compiled_group)
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
            ip: unique_device_ip(unique_id, 5),
            hostname: "combined-server"
          },
          actor: actor
        )
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
          },
          actor: actor
        )
        |> Ash.create()

      ConfigServer.invalidate(:sweep)

      {:ok, entry} = ConfigServer.get_config(:sweep, "default", nil)

      compiled_group =
        Enum.find(entry.config["groups"], fn g ->
          g["name"] == "Combined Targets Group #{unique_id}"
        end)

      assert compiled_group
      # Should have both criteria-matched and static targets
      assert device.ip in device_target_networks(compiled_group)
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
          },
          actor: actor
        )
        |> Ash.create()

      ConfigServer.invalidate(:sweep)

      {:ok, entry} = ConfigServer.get_config(:sweep, "default", nil)

      compiled_group =
        Enum.find(entry.config["groups"], fn g ->
          g["name"] == "Static Only Group #{unique_id}"
        end)

      assert compiled_group
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
          },
          actor: actor
        )
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
          },
          actor: actor
        )
        |> Ash.create()

      ConfigServer.invalidate(:sweep)

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
      register_agent(agent_id, actor)

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
          },
          actor: actor
        )
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
          },
          actor: actor
        )
        |> Ash.create()

      ConfigServer.invalidate(:sweep)

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
      register_agent(agent_id, actor)

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
          },
          actor: actor
        )
        |> Ash.create()

      ConfigServer.invalidate(:sweep)

      # Get config for different agent
      {:ok, entry} = ConfigServer.get_config(:sweep, "default", other_agent_id)

      group_names = Enum.map(entry.config["groups"], & &1["name"])

      # Should NOT include group assigned to different agent
      refute "Owner Only Group #{unique_id}" in group_names
    end
  end

  describe "canonical agent assignment eligibility" do
    test "the shared read action applies partition-wide and fixed-subset groups", %{
      actor: actor,
      unique_id: unique_id
    } do
      selected_a = register_agent("agent-selected-a-#{unique_id}", actor)
      selected_b = register_agent("agent-selected-b-#{unique_id}", actor)
      unselected = register_agent("agent-unselected-#{unique_id}", actor)
      partition = "agent-assignment-#{unique_id}"
      other_partition = "agent-assignment-other-#{unique_id}"

      {:ok, partition_wide} =
        create_group("Partition wide #{unique_id}", partition, %{agent_ids: []}, actor)

      {:ok, selected} =
        create_group(
          "Selected subset #{unique_id}",
          other_partition,
          %{agent_ids: [selected_a.uid, selected_b.uid]},
          actor
        )

      {:ok, deselected} =
        create_group(
          "Deselected subset #{unique_id}",
          other_partition,
          %{agent_ids: [unselected.uid]},
          actor
        )

      {:ok, disabled} =
        create_group(
          "Disabled subset #{unique_id}",
          other_partition,
          %{agent_ids: [selected_a.uid], enabled: false},
          actor
        )

      selected_a_ids = eligible_group_ids(selected_a.uid, partition, actor)
      selected_b_ids = eligible_group_ids(selected_b.uid, partition, actor)
      unselected_ids = eligible_group_ids(unselected.uid, partition, actor)
      nil_requester_ids = eligible_group_ids(nil, partition, actor)
      blank_requester_ids = eligible_group_ids("", partition, actor)

      assert partition_wide.id in selected_a_ids
      assert partition_wide.id in selected_b_ids
      assert partition_wide.id in unselected_ids
      assert partition_wide.id in nil_requester_ids
      assert partition_wide.id in blank_requester_ids

      assert selected.id in selected_a_ids
      assert selected.id in selected_b_ids
      refute selected.id in unselected_ids
      refute selected.id in nil_requester_ids
      refute selected.id in blank_requester_ids

      refute deselected.id in selected_a_ids
      refute disabled.id in selected_a_ids
    end

    test "a subset reassignment invalidates every warmed agent config before recompiling", %{
      actor: actor,
      unique_id: unique_id
    } do
      deselected_agent = register_agent("agent-deselected-#{unique_id}", actor)
      selected_agent = register_agent("agent-selected-#{unique_id}", actor)
      partition = "assignment-invalidation-#{unique_id}"

      {:ok, group} =
        create_group(
          "Invalidate subset #{unique_id}",
          partition,
          %{agent_ids: [deselected_agent.uid]},
          actor
        )

      {:ok, initially_deselected} =
        ConfigServer.get_config(:sweep, partition, deselected_agent.uid)

      {:ok, initially_unselected} = ConfigServer.get_config(:sweep, partition, selected_agent.uid)

      assert group.id in config_group_ids(initially_deselected)
      refute group.id in config_group_ids(initially_unselected)

      assert {:ok, _} = ConfigCache.get(:sweep, partition, deselected_agent.uid)
      assert {:ok, _} = ConfigCache.get(:sweep, partition, selected_agent.uid)

      DependencyDiagnostics.clear()

      assert {:ok, _updated} =
               group
               |> Ash.Changeset.for_update(:update, %{agent_ids: [selected_agent.uid]},
                 actor: actor
               )
               |> Ash.update()

      assert_eventually(
        fn ->
          Enum.any?(DependencyDiagnostics.recent(), fn diagnostic ->
            diagnostic.dependency_id == :sweep_group_config and
              diagnostic.action_type == :update and
              diagnostic.affected_agents == :all_online and diagnostic.result == :ok
          end)
        end,
        "fleet-wide sweep update dispatch"
      )

      assert_eventually(
        fn ->
          ConfigCache.get(:sweep, partition, deselected_agent.uid) == :miss and
            ConfigCache.get(:sweep, partition, selected_agent.uid) == :miss
        end,
        "both warmed sweep configs to be invalidated"
      )

      {:ok, recomputed_deselected} =
        ConfigServer.get_config(:sweep, partition, deselected_agent.uid)

      {:ok, recomputed_selected} = ConfigServer.get_config(:sweep, partition, selected_agent.uid)

      refute group.id in config_group_ids(recomputed_deselected)
      assert group.id in config_group_ids(recomputed_selected)
    end

    test "the explicit-membership predicate can use the sweep-group GIN index", %{
      actor: actor,
      unique_id: unique_id
    } do
      agent = register_agent("agent-index-#{unique_id}", actor)
      partition = "assignment-index-#{unique_id}"

      for index <- 1..32 do
        assert {:ok, _group} =
                 create_group(
                   "Index subset #{unique_id}-#{index}",
                   partition,
                   %{agent_ids: [agent.uid]},
                   actor
                 )
      end

      {:ok, ecto_query} =
        SweepGroup
        |> Ash.Query.for_read(:for_agent_partition, %{agent_id: agent.uid, partition: partition})
        |> Ash.Query.data_layer_query()

      {sql, params} = Ecto.Adapters.SQL.to_sql(:all, Repo, ecto_query)

      assert {:ok, %{rows: plan_rows}} =
               Repo.transaction(fn ->
                 assert %{command: :set} = Repo.query!("SET LOCAL enable_seqscan = off")
                 Repo.query!("EXPLAIN (COSTS OFF) #{sql}", params)
               end)

      plan = Enum.map_join(plan_rows, "\n", &hd/1)
      assert plan =~ "sweep_groups_agent_ids_gin_idx"
      assert plan =~ "Index Cond: (agent_ids @>"
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
          },
          actor: actor
        )
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
          },
          actor: actor
        )
        |> Ash.create()

      ConfigServer.invalidate(:sweep)

      {:ok, entry} = ConfigServer.get_config(:sweep, "default", nil)

      compiled_group =
        Enum.find(entry.config["groups"], fn g ->
          g["name"] == "Profile Group #{unique_id}"
        end)

      assert compiled_group
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
          },
          actor: actor
        )
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

  defp unique_device_ip(unique_id, offset) do
    third = rem(unique_id + offset, 200)
    fourth = rem(unique_id * 7 + offset * 13, 200) + 10
    "10.#{third}.#{offset}.#{fourth}"
  end

  defp non_matching_device_ip(unique_id, offset) do
    third = rem(unique_id + offset, 200)
    fourth = rem(unique_id * 11 + offset * 17, 200) + 10
    "192.168.#{third}.#{fourth}"
  end

  defp device_target_networks(compiled_group) do
    Enum.map(compiled_group["device_targets"] || [], & &1["network"])
  end

  defp eligible_group_ids(agent_id, partition, actor) do
    SweepGroup
    |> Ash.Query.for_read(:for_agent_partition, %{agent_id: agent_id, partition: partition})
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.id)
  end

  defp config_group_ids(config_entry) do
    Enum.map(config_entry.config["groups"] || [], & &1["sweep_group_id"])
  end

  defp assert_eventually(predicate, artifact, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_artifact(predicate, artifact, deadline)
  end

  defp await_artifact(predicate, artifact, deadline) do
    if predicate.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("Timed out waiting for #{artifact}")
      else
        Process.sleep(10)
        await_artifact(predicate, artifact, deadline)
      end
    end
  end

  defp create_group(name, partition, attrs, actor) do
    SweepGroup
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          name: name,
          partition: partition,
          interval: "15m",
          static_targets: ["10.0.0.1"]
        },
        attrs
      ),
      actor: actor
    )
    |> Ash.create()
  end

  defp register_agent(uid, actor) do
    Agent
    |> Ash.Changeset.for_create(:register, %{uid: uid}, actor: actor)
    |> Ash.create!()
  end
end
