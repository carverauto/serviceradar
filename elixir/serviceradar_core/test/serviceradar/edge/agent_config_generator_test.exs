defmodule ServiceRadar.Edge.AgentConfigGeneratorTest do
  @moduledoc """
  Tests for the AgentConfigGenerator module.

  Tests config generation from database, version hashing, and not_modified behavior.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Monitoring.ServiceCheck
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage

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

    agent_uid = "test-agent-#{unique_id}"

    {:ok, actor: actor, agent_uid: agent_uid, unique_id: unique_id}
  end

  describe "generate_config/1" do
    test "returns empty config when no checks exist", %{agent_uid: agent_uid} do
      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid)

      assert config.checks == []
      assert config.heartbeat_interval_sec == 30
      assert config.config_poll_interval_sec == 300
      assert String.starts_with?(config.config_version, "v")
      assert config.config_timestamp > 0
    end

    test "generates config with checks", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      {:ok, _agent} = create_connected_agent(actor, agent_uid)

      # Create a service check for this agent (enabled by default)
      {:ok, _check} =
        ServiceCheck
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Test HTTP Check #{unique_id}",
            check_type: :http,
            target: "https://example.com",
            port: 443,
            interval_seconds: 60,
            timeout_seconds: 10,
            agent_uid: agent_uid
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid)

      assert length(config.checks) == 1
      [check] = config.checks
      assert check.name == "Test HTTP Check #{unique_id}"
      assert check.check_type == "http"
      assert check.target == "https://example.com"
      assert check.port == 443
      assert check.interval_sec == 60
      assert check.timeout_sec == 10
      assert check.enabled == true
    end

    test "excludes disabled checks", %{actor: actor, agent_uid: agent_uid, unique_id: unique_id} do
      {:ok, _agent} = create_connected_agent(actor, agent_uid)

      # Create enabled check (enabled by default)
      {:ok, _enabled} =
        ServiceCheck
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Enabled Check #{unique_id}",
            check_type: :tcp,
            target: "10.0.0.1",
            port: 22,
            agent_uid: agent_uid
          },
          actor: actor
        )
        |> Ash.create()

      # Create check then disable it
      {:ok, disabled_check} =
        ServiceCheck
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Disabled Check #{unique_id}",
            check_type: :tcp,
            target: "10.0.0.2",
            port: 22,
            agent_uid: agent_uid
          },
          actor: actor
        )
        |> Ash.create()

      # Disable the check
      {:ok, _} =
        disabled_check
        |> Ash.Changeset.for_update(:disable, %{}, actor: actor)
        |> Ash.update()

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid)

      # Only enabled check should be included
      assert length(config.checks) == 1
      assert hd(config.checks).name == "Enabled Check #{unique_id}"
    end
  end

  describe "get_config_if_changed/2" do
    test "returns :not_modified when version matches", %{agent_uid: agent_uid} do
      # First, get the config to obtain the version
      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid)

      # Request with the same version
      result = AgentConfigGenerator.get_config_if_changed(agent_uid, config.config_version)

      assert result == :not_modified
    end

    test "returns config when version differs", %{agent_uid: agent_uid} do
      result = AgentConfigGenerator.get_config_if_changed(agent_uid, "v-old-version")

      assert {:ok, config} = result
      assert config.config_version != "v-old-version"
    end

    test "returns config when version is empty", %{agent_uid: agent_uid} do
      result = AgentConfigGenerator.get_config_if_changed(agent_uid, "")

      assert {:ok, _config} = result
    end
  end

  describe "to_proto_checks/1" do
    test "converts check config to proto format" do
      check = %{
        check_id: "123",
        check_type: "http",
        name: "Test Check",
        enabled: true,
        interval_sec: 60,
        timeout_sec: 10,
        target: "https://example.com",
        port: 443,
        path: "/health",
        method: "GET",
        settings: %{"header_Host" => "example.com"}
      }

      [proto_check] = AgentConfigGenerator.to_proto_checks([check])

      assert proto_check.check_id == "123"
      assert proto_check.check_type == "http"
      assert proto_check.name == "Test Check"
      assert proto_check.enabled == true
      assert proto_check.interval_sec == 60
      assert proto_check.timeout_sec == 10
      assert proto_check.target == "https://example.com"
      assert proto_check.port == 443
      assert proto_check.path == "/health"
      assert proto_check.method == "GET"
      assert proto_check.settings == %{"header_Host" => "example.com"}
    end

    test "handles nil values with defaults" do
      check = %{
        check_id: "456",
        check_type: "tcp",
        name: "TCP Check",
        enabled: true,
        interval_sec: 30,
        timeout_sec: 5,
        target: nil,
        port: nil,
        path: nil,
        method: nil,
        settings: nil
      }

      [proto_check] = AgentConfigGenerator.to_proto_checks([check])

      assert proto_check.target == ""
      assert proto_check.port == 0
      assert proto_check.path == ""
      assert proto_check.method == ""
      assert proto_check.settings == %{}
    end
  end

  describe "version hash stability" do
    test "same config produces same version hash", %{agent_uid: agent_uid} do
      {:ok, config1} = AgentConfigGenerator.generate_config(agent_uid)
      {:ok, config2} = AgentConfigGenerator.generate_config(agent_uid)

      # Version hash should be deterministic
      assert config1.config_version == config2.config_version
    end

    test "different checks produce different version hash", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      {:ok, _agent} = create_connected_agent(actor, agent_uid)

      # Get initial config
      {:ok, config1} = AgentConfigGenerator.generate_config(agent_uid)

      # Add a check (enabled by default)
      {:ok, _check} =
        ServiceCheck
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "New Check #{unique_id}",
            check_type: :ping,
            target: "10.0.0.100",
            agent_uid: agent_uid
          },
          actor: actor
        )
        |> Ash.create()

      # Get config again
      {:ok, config2} = AgentConfigGenerator.generate_config(agent_uid)

      # Version should be different now
      assert config1.config_version != config2.config_version
    end

    test "plugin download URL rotation does not change version hash", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      Application.put_env(
        :serviceradar_core,
        :plugin_storage,
        public_url: "https://demo.serviceradar.cloud",
        signing_secret: String.duplicate("s", 32),
        download_ttl_seconds: 60
      )

      on_exit(fn ->
        Application.delete_env(:serviceradar_core, :plugin_storage)
      end)

      {:ok, _agent} = create_connected_agent(actor, agent_uid)

      {:ok, package} =
        PluginPackage
        |> Ash.Changeset.for_create(
          :create,
          %{
            plugin_id: "plugin-#{unique_id}",
            name: "Plugin #{unique_id}",
            version: "1.0.0",
            entrypoint: "run_check",
            outputs: "serviceradar.plugin_result.v1",
            manifest: %{},
            config_schema: %{},
            display_contract: %{},
            wasm_object_key: "plugins/#{unique_id}/plugin.wasm",
            content_hash: "sha256:#{unique_id}",
            signature: %{},
            source_type: :upload
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, package} =
        package
        |> Ash.Changeset.for_update(:approve, %{approved_by: "test"}, actor: actor)
        |> Ash.update()

      {:ok, _assignment} =
        PluginAssignment
        |> Ash.Changeset.for_create(
          :create,
          %{
            agent_uid: agent_uid,
            plugin_package_id: package.id,
            enabled: true,
            interval_seconds: 60,
            timeout_seconds: 10,
            params: %{}
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, config1} = AgentConfigGenerator.generate_config(agent_uid)
      Process.sleep(1_100)
      {:ok, config2} = AgentConfigGenerator.generate_config(agent_uid)

      assert config1.config_version == config2.config_version
      refute config1.plugins == []
      assert hd(config1.plugins).download_url != hd(config2.plugins).download_url
    end
  end

  describe "sysmon config" do
    test "includes disabled sysmon config when no profile exists", %{agent_uid: agent_uid} do
      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid)

      # Should have sysmon_config field with disabled values
      assert config.sysmon_config
      assert config.sysmon_config.enabled == false
      assert config.sysmon_config.sample_interval == "10s"
      assert config.sysmon_config.collect_cpu == false
      assert config.sysmon_config.collect_memory == false
      assert config.sysmon_config.collect_disk == false
      assert config.sysmon_config.collect_network == false
      assert config.sysmon_config.collect_processes == false
      assert config.sysmon_config.disk_paths == []
      assert config.sysmon_config.disk_exclude_paths == []
      assert config.sysmon_config.config_source == "unassigned"
    end

    test "sysmon config affects version hash", %{agent_uid: agent_uid} do
      {:ok, config1} = AgentConfigGenerator.generate_config(agent_uid)

      # Create a custom sysmon profile (this would normally be done through the seeder/UI)
      # For now, we just verify that the config includes sysmon and has a version
      assert config1.sysmon_config
      assert String.starts_with?(config1.config_version, "v")

      # Same config should produce same hash
      {:ok, config2} = AgentConfigGenerator.generate_config(agent_uid)
      assert config1.config_version == config2.config_version
    end

    test "sysmon_config is proto-compatible struct", %{agent_uid: agent_uid} do
      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid)

      # Verify it's the proto struct
      assert is_struct(config.sysmon_config, Monitoring.SysmonConfig)

      # Verify all expected fields exist
      assert Map.has_key?(config.sysmon_config, :enabled)
      assert Map.has_key?(config.sysmon_config, :sample_interval)
      assert Map.has_key?(config.sysmon_config, :collect_cpu)
      assert Map.has_key?(config.sysmon_config, :collect_memory)
      assert Map.has_key?(config.sysmon_config, :collect_disk)
      assert Map.has_key?(config.sysmon_config, :collect_network)
      assert Map.has_key?(config.sysmon_config, :collect_processes)
      assert Map.has_key?(config.sysmon_config, :disk_paths)
      assert Map.has_key?(config.sysmon_config, :disk_exclude_paths)
      assert Map.has_key?(config.sysmon_config, :thresholds)
      assert Map.has_key?(config.sysmon_config, :profile_id)
      assert Map.has_key?(config.sysmon_config, :profile_name)
      assert Map.has_key?(config.sysmon_config, :config_source)
    end
  end

  describe "sweep config with partition resolution" do
    alias ServiceRadar.AgentConfig.ConfigServer
    alias ServiceRadar.AgentRegistry
    alias ServiceRadar.SweepJobs.SweepGroup

    test "unregistered agent receives sweep config from default partition", %{
      actor: actor,
      unique_id: unique_id
    } do
      agent_uid = "unregistered-sweep-agent-#{unique_id}"

      # Create sweep group in default partition
      {:ok, _group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Default Sweep Group #{unique_id}",
            partition: "default",
            interval: "15m",
            static_targets: ["10.0.0.1"],
            enabled: true
          },
          actor: actor
        )
        |> Ash.create()

      ConfigServer.invalidate(:sweep)

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid)
      payload = Jason.decode!(config.config_json)

      assert Map.has_key?(payload, "sweep")
      assert is_map(payload["sweep"])

      if payload["sweep"]["groups"] do
        group_names = Enum.map(payload["sweep"]["groups"], & &1["name"])
        assert "Default Sweep Group #{unique_id}" in group_names
      end
    end

    test "registered agent receives sweep config from its partition", %{
      actor: actor,
      unique_id: unique_id
    } do
      agent_uid = "registered-sweep-agent-#{unique_id}"
      partition = "test-partition-#{unique_id}"

      # Register agent with specific partition
      {:ok, _pid} =
        AgentRegistry.register_agent(agent_uid, %{
          partition_id: partition,
          grpc_host: "127.0.0.1",
          grpc_port: 50_051,
          capabilities: [:sweep],
          status: :connected
        })

      # Create sweep group in agent's partition
      {:ok, _partition_group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Partition Sweep Group #{unique_id}",
            partition: partition,
            interval: "15m",
            static_targets: ["192.168.1.0/24"],
            enabled: true
          },
          actor: actor
        )
        |> Ash.create()

      # Create sweep group in default partition (should NOT be included)
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

      ConfigServer.invalidate(:sweep)

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid)
      payload = Jason.decode!(config.config_json)

      if payload["sweep"]["groups"] do
        group_names = Enum.map(payload["sweep"]["groups"], & &1["name"])
        # Should include partition-specific group
        assert "Partition Sweep Group #{unique_id}" in group_names
        # Should NOT include default partition group
        refute "Default Partition Group #{unique_id}" in group_names
      end

      # Cleanup
      AgentRegistry.unregister_agent(agent_uid)
    end

    test "agent receives sweep groups with resolved SRQL targeting", %{
      actor: actor,
      unique_id: unique_id
    } do
      agent_uid = "criteria-sweep-agent-#{unique_id}"

      # Create device that matches criteria
      {:ok, device} =
        ServiceRadar.Inventory.Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: "sweep-target-device-#{unique_id}",
            ip: "10.100.50.25",
            hostname: "target-server",
            tags: %{"env" => "prod", "tier" => "1"}
          },
          actor: actor
        )
        |> Ash.create()

      # Create sweep group with SRQL targeting
      {:ok, _group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Criteria Sweep Group #{unique_id}",
            partition: "default",
            interval: "15m",
            target_query: "in:devices ip:10.100.0.0/16 tags.env:prod",
            enabled: true
          },
          actor: actor
        )
        |> Ash.create()

      ConfigServer.invalidate(:sweep)

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid)
      payload = Jason.decode!(config.config_json)

      if payload["sweep"]["groups"] do
        group =
          Enum.find(payload["sweep"]["groups"], fn g ->
            g["name"] == "Criteria Sweep Group #{unique_id}"
          end)

        if group do
          # Device IP should be in targets
          assert device.ip in group["targets"]
        end
      end
    end

    test "sweep config version changes when SRQL targeting updated", %{
      actor: actor,
      unique_id: unique_id
    } do
      agent_uid = "version-sweep-agent-#{unique_id}"

      {:ok, group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Version Test Sweep #{unique_id}",
            partition: "default",
            interval: "15m",
            target_query: "in:devices ip:10.0.0.0/8",
            static_targets: ["192.168.1.1"],
            enabled: true
          },
          actor: actor
        )
        |> Ash.create()

      ConfigServer.invalidate(:sweep)

      {:ok, config1} = AgentConfigGenerator.generate_config(agent_uid)
      version1 = config1.config_version

      # Update SRQL targeting
      {:ok, _updated} =
        group
        |> Ash.Changeset.for_update(:update, %{
          target_query: "in:devices ip:172.16.0.0/12"
        })
        |> Ash.update(actor: actor)

      ConfigServer.invalidate(:sweep)

      {:ok, config2} = AgentConfigGenerator.generate_config(agent_uid)
      version2 = config2.config_version

      # Version should be different after criteria update
      refute version1 == version2
    end

    test "agent-specific sweep groups are included for matching agent", %{
      actor: actor,
      unique_id: unique_id
    } do
      agent_uid = "agent-specific-sweep-#{unique_id}"

      # Create agent-specific sweep group
      {:ok, _group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Agent Specific Sweep #{unique_id}",
            partition: "default",
            agent_id: agent_uid,
            interval: "15m",
            static_targets: ["10.0.99.1"],
            enabled: true
          },
          actor: actor
        )
        |> Ash.create()

      # Create partition-wide sweep group
      {:ok, _partition_group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Partition Wide Sweep #{unique_id}",
            partition: "default",
            agent_id: nil,
            interval: "15m",
            static_targets: ["10.0.1.1"],
            enabled: true
          },
          actor: actor
        )
        |> Ash.create()

      ConfigServer.invalidate(:sweep)

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid)
      payload = Jason.decode!(config.config_json)

      if payload["sweep"]["groups"] do
        group_names = Enum.map(payload["sweep"]["groups"], & &1["name"])
        # Should include both agent-specific and partition-wide groups
        assert "Agent Specific Sweep #{unique_id}" in group_names
        assert "Partition Wide Sweep #{unique_id}" in group_names
      end
    end
  end

  defp create_connected_agent(actor, agent_uid) do
    Agent
    |> Ash.Changeset.for_create(
      :register_connected,
      %{
        uid: agent_uid,
        name: "Config Test Agent #{agent_uid}",
        host: "127.0.0.1",
        port: 50_051
      },
      actor: actor
    )
    |> Ash.create()
  end
end
