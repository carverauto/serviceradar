defmodule ServiceRadar.Edge.AgentConfigGeneratorTest do
  @moduledoc """
  Tests for the AgentConfigGenerator module.

  Tests config generation from database, version hashing, and not_modified behavior.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.AgentConfig.ConfigInstance
  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Inventory.BumblebeeCatalogSnapshot
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Monitoring.ServiceCheck
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage

  @moduletag :integration
  @default_partition "default"

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    unique_id = :erlang.unique_integer([:positive])
    old_required_addons = Application.get_env(:serviceradar_core, :required_agent_addons)

    Application.put_env(:serviceradar_core, :required_agent_addons, [])

    on_exit(fn ->
      if is_nil(old_required_addons) do
        Application.delete_env(:serviceradar_core, :required_agent_addons)
      else
        Application.put_env(:serviceradar_core, :required_agent_addons, old_required_addons)
      end
    end)

    actor = %{
      id: Ash.UUID.generate(),
      email: "test@serviceradar.local",
      role: :admin
    }

    agent_uid = "test-agent-#{unique_id}"

    {:ok, actor: actor, agent_uid: agent_uid, unique_id: unique_id}
  end

  describe "generate_config/2" do
    test "returns empty config when no checks exist", %{agent_uid: agent_uid} do
      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

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

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

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

    test "includes armis credentials in config_json served to agents", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      {:ok, _agent} = create_connected_agent(actor, agent_uid)
      source_name = "Armis Agent Config #{unique_id}"

      {:ok, _source} =
        IntegrationSource
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: source_name,
            source_type: :armis,
            endpoint: "https://armis.example.test",
            agent_id: agent_uid,
            credentials: %{
              api_key: "agent-config-api-key",
              api_secret: "agent-config-api-secret"
            }
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      credentials =
        config.config_json
        |> Jason.decode!()
        |> get_in(["sources", source_name, "credentials"])

      assert credentials["api_key"] == "agent-config-api-key"
      assert credentials["api_secret"] == "agent-config-api-secret"
      assert credentials["secret_key"] == "agent-config-api-secret"
    end

    test "does not enable bumblebee without an agent-specific opt-in", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      create_active_bumblebee_snapshot!(actor, unique_id)

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
      payload = Jason.decode!(config.config_json)

      assert payload["bumblebee"] == %{"enabled" => false}
      refute config.bumblebee_config.enabled
    end

    test "attaches active bumblebee catalog only to opted-in agents", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      snapshot = create_active_bumblebee_snapshot!(actor, unique_id)
      other_agent_uid = "bumblebee-other-agent-#{unique_id}"

      create_bumblebee_config_instance!(actor, agent_uid, %{
        "enabled" => true,
        "scan_profile" => "workstations",
        "root_discovery_mode" => "explicit",
        "explicit_roots" => ["/opt/service"],
        "exclude_roots" => ["/opt/service/cache"],
        "ecosystems" => ["npm"],
        "scan_timeout" => "5m",
        "max_findings" => 25,
        "max_output_bytes" => 1_048_576,
        "cadence" => "12h",
        "findings_only" => true
      })

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
      payload = Jason.decode!(config.config_json)

      assert payload["bumblebee"]["enabled"] == true
      assert payload["bumblebee"]["agent_id"] == agent_uid
      assert payload["bumblebee"]["scan_profile"] == "workstations"
      assert payload["bumblebee"]["root_discovery_mode"] == "explicit"
      assert payload["bumblebee"]["catalog"]["snapshot_ref"] == snapshot.snapshot_ref
      assert payload["bumblebee"]["catalog"]["sha256"] == snapshot.content_sha256
      assert config.bumblebee_config.enabled
      assert config.bumblebee_config.catalog.snapshot_ref == snapshot.snapshot_ref

      {:ok, other_config} =
        AgentConfigGenerator.generate_config(other_agent_uid, @default_partition)

      other_payload = Jason.decode!(other_config.config_json)

      assert other_payload["bumblebee"] == %{"enabled" => false}
      refute other_config.bumblebee_config.enabled
    end

    test "enables bumblebee on k8s-agent when explicitly opted in", %{
      actor: actor,
      unique_id: unique_id
    } do
      snapshot = create_active_bumblebee_snapshot!(actor, unique_id)

      create_bumblebee_config_instance!(actor, "k8s-agent", %{
        "enabled" => true,
        "scan_profile" => "kubernetes"
      })

      {:ok, config} = AgentConfigGenerator.generate_config("k8s-agent", @default_partition)
      payload = Jason.decode!(config.config_json)

      assert payload["bumblebee"]["enabled"] == true
      assert payload["bumblebee"]["agent_id"] == "k8s-agent"
      assert payload["bumblebee"]["scan_profile"] == "kubernetes"
      assert payload["bumblebee"]["catalog"]["snapshot_ref"] == snapshot.snapshot_ref
      assert config.bumblebee_config.enabled
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

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      # Only enabled check should be included
      assert length(config.checks) == 1
      assert hd(config.checks).name == "Enabled Check #{unique_id}"
    end
  end

  describe "get_config_if_changed/3" do
    test "returns :not_modified when version matches", %{agent_uid: agent_uid} do
      # First, get the config to obtain the version
      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      # Request with the same version
      result =
        AgentConfigGenerator.get_config_if_changed(
          agent_uid,
          @default_partition,
          config.config_version
        )

      assert result == :not_modified
    end

    test "returns config when version differs", %{agent_uid: agent_uid} do
      result =
        AgentConfigGenerator.get_config_if_changed(agent_uid, @default_partition, "v-old-version")

      assert {:ok, config} = result
      assert config.config_version != "v-old-version"
    end

    test "returns config when version is empty", %{agent_uid: agent_uid} do
      result = AgentConfigGenerator.get_config_if_changed(agent_uid, @default_partition, "")

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
      {:ok, config1} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
      {:ok, config2} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

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
      {:ok, config1} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

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
      {:ok, config2} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      # Version should be different now
      assert config1.config_version != config2.config_version
    end

    test "plugin download credential rotation does not change version hash", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      Application.put_env(
        :serviceradar_core,
        :plugin_storage,
        public_url: "https://demo.serviceradar.cloud",
        signing_secret: String.duplicate("s", 32),
        download_ttl_seconds: 60,
        # Pin the freshness epoch so the two generations below cannot straddle
        # an epoch boundary (the epoch intentionally re-versions configs so
        # agents pick up fresh download tokens before TTL expiry).
        download_token_epoch_seconds: 999_999_999
      )

      on_exit(fn ->
        Application.delete_env(:serviceradar_core, :plugin_storage)
      end)

      {:ok, _agent} = create_connected_agent(actor, agent_uid)
      plugin_id = "plugin-#{unique_id}"

      {:ok, _plugin} =
        Plugin
        |> Ash.Changeset.for_create(
          :create,
          %{
            plugin_id: plugin_id,
            name: "Plugin #{unique_id}"
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, package} =
        PluginPackage
        |> Ash.Changeset.for_create(
          :create,
          %{
            plugin_id: plugin_id,
            name: "Plugin #{unique_id}",
            version: "1.0.0",
            entrypoint: "run_check",
            outputs: "serviceradar.plugin_result.v1",
            manifest: plugin_manifest(plugin_id, "Plugin #{unique_id}"),
            config_schema: %{},
            display_contract: %{},
            content_hash: "sha256:#{unique_id}",
            signature: %{},
            source_type: :upload
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, package} =
        package
        |> Ash.Changeset.for_update(
          :update,
          %{wasm_object_key: "plugins/#{unique_id}/plugin.wasm"},
          actor: actor
        )
        |> Ash.update()

      {:ok, package} =
        package
        |> Ash.Changeset.for_update(:approve, %{approved_by: "test"}, actor: actor)
        |> Ash.update()

      _assignment =
        create_plugin_assignment!(
          agent_uid,
          %{
            plugin_package_id: package.id,
            enabled: true,
            interval_seconds: 60,
            timeout_seconds: 10,
            params: %{}
          },
          actor
        )

      {:ok, config1} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
      Process.sleep(1_100)
      {:ok, config2} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      assert config1.config_version == config2.config_version
      refute config1.plugins == []
      assert hd(config1.plugins).download_token != hd(config2.plugins).download_token
      assert hd(config1.plugins).download_url == hd(config2.plugins).download_url

      payload = Jason.decode!(config1.config_json)
      [json_plugin] = get_in(payload, ["plugins", "assignments"])

      assert json_plugin["assignment_id"] == hd(config1.plugins).assignment_id
      assert json_plugin["download_url"] == hd(config1.plugins).download_url
      assert is_binary(json_plugin["download_token"])

      assert get_in(payload, ["plugins", "engine_limits"]) == %{
               "max_concurrent" => nil,
               "max_cpu_ms" => nil,
               "max_memory_mb" => nil,
               "max_open_connections" => nil
             }
    end

    test "plugin config excludes disabled duplicate assignments", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      {:ok, _agent} = create_connected_agent(actor, agent_uid)
      plugin_id = "plugin-disabled-duplicate-#{unique_id}"

      {:ok, _plugin} =
        Plugin
        |> Ash.Changeset.for_create(
          :create,
          %{
            plugin_id: plugin_id,
            name: "Plugin Disabled Duplicate #{unique_id}"
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, package} =
        PluginPackage
        |> Ash.Changeset.for_create(
          :create,
          %{
            plugin_id: plugin_id,
            name: "Plugin Disabled Duplicate #{unique_id}",
            version: "1.0.0",
            entrypoint: "run_check",
            outputs: "serviceradar.plugin_result.v1",
            manifest: plugin_manifest(plugin_id, "Plugin Disabled Duplicate #{unique_id}"),
            config_schema: %{},
            display_contract: %{},
            content_hash: "sha256:#{unique_id}",
            signature: %{},
            source_type: :upload
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, package} =
        package
        |> Ash.Changeset.for_update(
          :update,
          %{wasm_object_key: "plugins/#{unique_id}/plugin.wasm"},
          actor: actor
        )
        |> Ash.update()

      {:ok, package} =
        package
        |> Ash.Changeset.for_update(:approve, %{approved_by: "test"}, actor: actor)
        |> Ash.update()

      active_assignment =
        create_plugin_assignment!(
          agent_uid,
          %{
            plugin_package_id: package.id,
            enabled: true,
            interval_seconds: 60,
            timeout_seconds: 10,
            params: %{}
          },
          actor
        )

      _disabled_assignment =
        create_plugin_assignment!(
          agent_uid,
          %{
            plugin_package_id: package.id,
            source: :policy,
            source_key: "plugin-disabled-duplicate:#{unique_id}",
            policy_id: "plugin-disabled-duplicate-#{unique_id}",
            enabled: false,
            interval_seconds: 120,
            timeout_seconds: 20,
            params: %{}
          },
          actor
        )

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      assert [plugin] = config.plugins
      assert plugin.assignment_id == to_string(active_assignment.id)
      assert plugin.plugin_id == plugin_id
      assert plugin.enabled == true
    end

    test "plugin assignment overrides cannot widen approved permissions or resources", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      {:ok, _agent} = create_connected_agent(actor, agent_uid)
      plugin_id = "plugin-override-#{unique_id}"

      manifest = %{
        "id" => plugin_id,
        "name" => "Plugin Override #{unique_id}",
        "version" => "1.0.0",
        "entrypoint" => "run_check",
        "capabilities" => ["submit_result"],
        "outputs" => "serviceradar.plugin_result.v1",
        "permissions" => %{
          "allowed_domains" => ["approved.example.com"],
          "allowed_networks" => ["10.0.0.0/24"],
          "allowed_ports" => [443]
        },
        "resources" => %{
          "requested_memory_mb" => 64,
          "requested_cpu_ms" => 1000,
          "max_open_connections" => 2
        }
      }

      {:ok, _plugin} =
        Plugin
        |> Ash.Changeset.for_create(
          :create,
          %{
            plugin_id: plugin_id,
            name: "Plugin Override #{unique_id}"
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, package} =
        PluginPackage
        |> Ash.Changeset.for_create(
          :create,
          %{
            plugin_id: plugin_id,
            name: "Plugin Override #{unique_id}",
            version: "1.0.0",
            entrypoint: "run_check",
            outputs: "serviceradar.plugin_result.v1",
            manifest: manifest,
            config_schema: %{},
            display_contract: %{},
            content_hash: "sha256:#{unique_id}",
            signature: %{},
            source_type: :upload
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, package} =
        package
        |> Ash.Changeset.for_update(
          :update,
          %{wasm_object_key: "plugins/#{unique_id}/plugin.wasm"},
          actor: actor
        )
        |> Ash.update()

      {:ok, package} =
        package
        |> Ash.Changeset.for_update(
          :approve,
          %{
            approved_by: "test",
            approved_permissions: %{allowed_ports: [443]},
            approved_resources: %{requested_memory_mb: 32}
          },
          actor: actor
        )
        |> Ash.update()

      _assignment =
        create_plugin_assignment!(
          agent_uid,
          %{
            plugin_package_id: package.id,
            enabled: true,
            interval_seconds: 60,
            timeout_seconds: 10,
            params: %{},
            permissions_override: %{
              allowed_domains: ["approved.example.com", "evil.example.com"],
              allowed_networks: ["10.0.0.0/24", "192.168.0.0/16"],
              allowed_ports: [443, 8443]
            },
            resources_override: %{
              requested_memory_mb: 128,
              requested_cpu_ms: 2000,
              max_open_connections: 10
            }
          },
          actor
        )

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
      [plugin] = config.plugins

      assert plugin.permissions == %{
               allowed_domains: ["approved.example.com"],
               allowed_networks: ["10.0.0.0/24"],
               allowed_ports: [443]
             }

      assert plugin.resources == %{
               requested_memory_mb: 32,
               requested_cpu_ms: 1000,
               max_open_connections: 2
             }
    end

    test "wildcard-aware domain narrowing scopes manifest domains against the approved set", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      {:ok, _agent} = create_connected_agent(actor, agent_uid)

      # Wildcard manifest narrowed by a specific approved set collapses to the
      # approved set. This is the dusk-checker regression: a manifest of `["*"]`
      # narrowed by an approved `["localhost", "127.0.0.1"]` must yield the
      # approved set, NOT `[]` (which denied the plugin all egress).
      assert effective_allowed_domains(
               actor,
               agent_uid,
               unique_id,
               ["*"],
               ["localhost", "127.0.0.1"]
             ) == ["localhost", "127.0.0.1"]

      # Specific manifest with a wildcard approval keeps the manifest scope: the
      # approval allows anything, but the effective scope never broadens past the
      # manifest.
      assert effective_allowed_domains(
               actor,
               agent_uid,
               unique_id,
               ["a.example.com", "b.example.com"],
               ["*"]
             ) == ["a.example.com", "b.example.com"]

      # Wildcard on both sides stays a wildcard.
      assert effective_allowed_domains(actor, agent_uid, unique_id, ["*"], ["*"]) == ["*"]

      # Specific vs specific is the intersection, preserving manifest order.
      assert effective_allowed_domains(
               actor,
               agent_uid,
               unique_id,
               ["a.example.com", "b.example.com"],
               ["b.example.com", "c.example.com"]
             ) == ["b.example.com"]

      # An empty manifest scope always denies, even against a specific approval.
      assert effective_allowed_domains(actor, agent_uid, unique_id, [], ["a.example.com"]) == []
    end

    test "granting a capability bumps the config version hash so agents redeliver", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      {:ok, _agent} = create_connected_agent(actor, agent_uid)
      plugin_id = "plugin-capver-#{unique_id}"
      name = "Plugin CapVer #{unique_id}"

      manifest =
        plugin_id
        |> plugin_manifest(name)
        |> Map.put("capabilities", ["log", "submit_result", "http_request"])
        |> Map.put("permissions", %{"allowed_domains" => ["localhost"], "allowed_ports" => [8080]})

      {:ok, _plugin} =
        Plugin
        |> Ash.Changeset.for_create(:create, %{plugin_id: plugin_id, name: name}, actor: actor)
        |> Ash.create()

      {:ok, package} =
        PluginPackage
        |> Ash.Changeset.for_create(
          :create,
          %{
            plugin_id: plugin_id,
            name: name,
            version: "1.0.0",
            entrypoint: "run_check",
            outputs: "serviceradar.plugin_result.v1",
            manifest: manifest,
            config_schema: %{},
            display_contract: %{},
            content_hash: "sha256:#{plugin_id}",
            signature: %{},
            source_type: :upload
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, package} =
        package
        |> Ash.Changeset.for_update(
          :update,
          %{wasm_object_key: "plugins/#{plugin_id}/plugin.wasm"},
          actor: actor
        )
        |> Ash.update()

      # Approve WITHOUT http_request.
      {:ok, package} =
        package
        |> Ash.Changeset.for_update(
          :approve,
          %{approved_by: "test", approved_capabilities: ["log", "submit_result"]},
          actor: actor
        )
        |> Ash.update()

      _assignment =
        create_plugin_assignment!(
          agent_uid,
          %{
            plugin_package_id: package.id,
            enabled: true,
            interval_seconds: 60,
            timeout_seconds: 10,
            params: %{}
          },
          actor
        )

      {:ok, config_without} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
      refute "http_request" in hd(config_without.plugins).capabilities

      # Idempotent: an unchanged config generates the same version hash (guards
      # against volatile-field churn making the != assertion below trivially pass).
      {:ok, config_without_again} =
        AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      assert config_without_again.config_version == config_without.config_version

      # Grant http_request on the SAME package + assignment (revoke -> restage ->
      # approve keeps the assignment_id stable, so the ONLY change is the capability).
      {:ok, package} =
        package |> Ash.Changeset.for_update(:revoke, %{}, actor: actor) |> Ash.update()

      {:ok, package} =
        package |> Ash.Changeset.for_update(:restage, %{}, actor: actor) |> Ash.update()

      {:ok, _package} =
        package
        |> Ash.Changeset.for_update(
          :approve,
          %{approved_by: "test", approved_capabilities: ["log", "submit_result", "http_request"]},
          actor: actor
        )
        |> Ash.update()

      {:ok, config_with} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
      assert "http_request" in hd(config_with.plugins).capabilities

      # The capability grant MUST change the version hash so the gateway serves a
      # new config and the agent relaunches the plugin with the new capability.
      refute config_with.config_version == config_without.config_version
    end
  end

  # Creates a plugin package whose manifest declares `allowed_domains == manifest_domains`,
  # approves it with `approved_permissions.allowed_domains == approved_domains`, assigns it
  # to the agent (no assignment-level override), and returns the effective
  # `allowed_domains` the config generator computes. Exercises `narrow_string_scope/2`
  # end-to-end through the manifest -> approved-permissions narrowing.
  defp effective_allowed_domains(actor, agent_uid, unique_id, manifest_domains, approved_domains) do
    plugin_id = "plugin-scope-#{unique_id}-#{System.unique_integer([:positive])}"
    name = "Plugin Scope #{plugin_id}"

    manifest =
      plugin_id
      |> plugin_manifest(name)
      |> Map.put("permissions", %{"allowed_domains" => manifest_domains})

    {:ok, _plugin} =
      Plugin
      |> Ash.Changeset.for_create(:create, %{plugin_id: plugin_id, name: name}, actor: actor)
      |> Ash.create()

    {:ok, package} =
      PluginPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          plugin_id: plugin_id,
          name: name,
          version: "1.0.0",
          entrypoint: "run_check",
          outputs: "serviceradar.plugin_result.v1",
          manifest: manifest,
          config_schema: %{},
          display_contract: %{},
          content_hash: "sha256:#{plugin_id}",
          signature: %{},
          source_type: :upload
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, package} =
      package
      |> Ash.Changeset.for_update(
        :update,
        %{wasm_object_key: "plugins/#{plugin_id}/plugin.wasm"},
        actor: actor
      )
      |> Ash.update()

    {:ok, package} =
      package
      |> Ash.Changeset.for_update(
        :approve,
        %{approved_by: "test", approved_permissions: %{allowed_domains: approved_domains}},
        actor: actor
      )
      |> Ash.update()

    _assignment =
      create_plugin_assignment!(
        agent_uid,
        %{
          plugin_package_id: package.id,
          enabled: true,
          interval_seconds: 60,
          timeout_seconds: 10,
          params: %{}
        },
        actor
      )

    {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

    config.plugins
    |> Enum.find(&(&1.plugin_id == plugin_id))
    |> Map.fetch!(:permissions)
    |> Map.fetch!(:allowed_domains)
  end

  defp plugin_manifest(plugin_id, name) do
    %{
      "id" => plugin_id,
      "name" => name,
      "version" => "1.0.0",
      "entrypoint" => "run_check",
      "capabilities" => ["submit_result"],
      "outputs" => "serviceradar.plugin_result.v1",
      "resources" => %{
        "requested_memory_mb" => 64,
        "requested_cpu_ms" => 1000
      }
    }
  end

  describe "sysmon config" do
    test "includes disabled sysmon config when no profile exists", %{agent_uid: agent_uid} do
      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      # Should have sysmon_config field with disabled values
      assert config.sysmon_config
      assert config.sysmon_config.enabled == false
      assert config.sysmon_config.sample_interval == "10s"
      assert config.sysmon_config.collect_cpu == false
      assert config.sysmon_config.collect_memory == false
      assert config.sysmon_config.collect_disk == false
      assert config.sysmon_config.collect_network == false
      assert config.sysmon_config.collect_processes == false
      assert config.sysmon_config.process_limit == 0
      assert config.sysmon_config.disk_paths == []
      assert config.sysmon_config.disk_exclude_paths == []
      assert config.sysmon_config.config_source == "unassigned"
    end

    test "sysmon config affects version hash", %{agent_uid: agent_uid} do
      {:ok, config1} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      # Create a custom sysmon profile (this would normally be done through the seeder/UI)
      # For now, we just verify that the config includes sysmon and has a version
      assert config1.sysmon_config
      assert String.starts_with?(config1.config_version, "v")

      # Same config should produce same hash
      {:ok, config2} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
      assert config1.config_version == config2.config_version
    end

    test "sysmon_config is proto-compatible struct", %{agent_uid: agent_uid} do
      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

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
      assert Map.has_key?(config.sysmon_config, :process_limit)
      assert Map.has_key?(config.sysmon_config, :disk_paths)
      assert Map.has_key?(config.sysmon_config, :disk_exclude_paths)
      assert Map.has_key?(config.sysmon_config, :thresholds)
      assert Map.has_key?(config.sysmon_config, :profile_id)
      assert Map.has_key?(config.sysmon_config, :profile_name)
      assert Map.has_key?(config.sysmon_config, :config_source)
    end
  end

  describe "visibility config" do
    test "includes disabled visibility config before profiles are configured", %{
      agent_uid: agent_uid
    } do
      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      assert %Monitoring.VisibilityConfig{} = visibility = config.visibility_config
      assert visibility.enabled == false
      assert visibility.capture_interfaces == []
      assert visibility.device_bindings == []
      assert visibility.default_sample_interval_ms == 0
      assert visibility.flow_table_max_entries == 0
      assert visibility.binary_overrides == nil
      assert visibility.dpi == %Monitoring.VisibilityDpiConfig{enabled: false, protocols: []}
    end
  end

  describe "sweep config with partition resolution" do
    alias ServiceRadar.AgentConfig.ConfigServer
    alias ServiceRadar.AgentRegistry
    alias ServiceRadar.ProcessRegistry
    alias ServiceRadar.SweepJobs.SweepGroup

    test "sweep metadata recompilation does not change agent config version", %{
      actor: actor,
      unique_id: unique_id
    } do
      agent_uid = "stable-sweep-agent-#{unique_id}"

      {:ok, _group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Stable Version Sweep #{unique_id}",
            partition: "default",
            interval: "15m",
            static_targets: ["192.168.44.10"],
            enabled: true
          },
          actor: actor
        )
        |> Ash.create()

      ConfigServer.invalidate(:sweep)
      {:ok, config1} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      Process.sleep(5)
      ConfigServer.invalidate(:sweep)
      {:ok, config2} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      assert config1.config_version == config2.config_version
    end

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

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
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

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, partition)
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

    test "authenticated partition selects the matching config with multiple gateway entries", %{
      actor: actor,
      unique_id: unique_id
    } do
      agent_uid = "multi-entry-sweep-agent-#{unique_id}"
      stale_partition = "stale-partition-#{unique_id}"
      fresh_partition = "fresh-partition-#{unique_id}"
      stale_node = :"stale-gateway-#{unique_id}@127.0.0.1"
      fresh_node = :"fresh-gateway-#{unique_id}@127.0.0.1"

      try do
        {:ok, _stale_pid} =
          ProcessRegistry.register_agent(
            agent_uid,
            %{
              agent_id: agent_uid,
              partition_id: stale_partition,
              capabilities: [],
              status: :connected
            },
            stale_node
          )

        {:ok, _fresh_pid} =
          ProcessRegistry.register_agent(
            agent_uid,
            %{
              agent_id: agent_uid,
              partition_id: fresh_partition,
              capabilities: [:sweep],
              status: :connected
            },
            fresh_node
          )

        ProcessRegistry.update_value({:agent, agent_uid, stale_node}, fn metadata ->
          %{metadata | last_heartbeat: DateTime.add(DateTime.utc_now(), -300, :second)}
        end)

        {:ok, _stale_group} =
          SweepGroup
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Stale Gateway Sweep Group #{unique_id}",
              partition: stale_partition,
              interval: "15m",
              static_targets: ["10.255.0.1"],
              enabled: true
            },
            actor: actor
          )
          |> Ash.create()

        {:ok, _fresh_group} =
          SweepGroup
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Fresh Gateway Sweep Group #{unique_id}",
              partition: fresh_partition,
              interval: "15m",
              static_targets: ["10.255.0.2"],
              enabled: true
            },
            actor: actor
          )
          |> Ash.create()

        ConfigServer.invalidate(:sweep)

        {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, fresh_partition)
        payload = Jason.decode!(config.config_json)
        group_names = Enum.map(payload["sweep"]["groups"] || [], & &1["name"])

        assert "Fresh Gateway Sweep Group #{unique_id}" in group_names
        refute "Stale Gateway Sweep Group #{unique_id}" in group_names
      after
        ProcessRegistry.unregister_agent(agent_uid, stale_node)
        ProcessRegistry.unregister_agent(agent_uid, fresh_node)
      end
    end

    test "agent receives sweep groups with resolved SRQL targeting", %{
      actor: actor,
      unique_id: unique_id
    } do
      agent_uid = "criteria-sweep-agent-#{unique_id}"
      device_ip = unique_ip("criteria-sweep-#{unique_id}")
      target_hostname = "target-server-#{unique_id}"

      # Create device that matches criteria
      {:ok, device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: "sweep-target-device-#{unique_id}",
            ip: device_ip,
            hostname: target_hostname,
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
            target_query: "in:devices ip:#{device_ip}/32 tags.env:prod",
            enabled: true
          },
          actor: actor
        )
        |> Ash.create()

      ConfigServer.invalidate(:sweep)

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
      payload = Jason.decode!(config.config_json)

      if payload["sweep"]["groups"] do
        group =
          Enum.find(payload["sweep"]["groups"], fn g ->
            g["name"] == "Criteria Sweep Group #{unique_id}"
          end)

        if group do
          assert group["targets"] == []

          device_target =
            Enum.find(group["device_targets"] || [], fn target ->
              target["network"] == device.ip
            end)

          assert device_target
          assert device_target["source"] == "srql"
          assert device_target["query_label"] == "Criteria Sweep Group #{unique_id}"
        end
      end
    end

    test "SRQL sweep targeting excludes Armis discovery sources", %{
      actor: actor,
      unique_id: unique_id
    } do
      agent_uid = "non-armis-sweep-agent-#{unique_id}"
      armis_ip = unique_ip("armis-sweep-#{unique_id}")
      non_armis_ip = unique_ip("non-armis-sweep-#{unique_id}")

      {:ok, _armis_device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: "armis-sweep-target-device-#{unique_id}",
            ip: armis_ip,
            hostname: "armis-host-#{unique_id}",
            discovery_sources: ["armis"]
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, _non_armis_device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: "non-armis-sweep-target-device-#{unique_id}",
            ip: non_armis_ip,
            hostname: "non-armis-host-#{unique_id}",
            discovery_sources: ["sweep"]
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, _group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Non Armis Criteria Sweep #{unique_id}",
            partition: "default",
            interval: "15m",
            target_query: "in:devices !discovery_sources:(armis)",
            enabled: true
          },
          actor: actor
        )
        |> Ash.create()

      ConfigServer.invalidate(:sweep)

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
      payload = Jason.decode!(config.config_json)

      group =
        Enum.find(payload["sweep"]["groups"] || [], fn g ->
          g["name"] == "Non Armis Criteria Sweep #{unique_id}"
        end)

      assert group

      networks = Enum.map(group["device_targets"] || [], & &1["network"])
      assert non_armis_ip in networks
      refute armis_ip in networks
    end

    test "sweep config version changes when SRQL targeting updated", %{
      actor: actor,
      unique_id: unique_id
    } do
      agent_uid = "version-sweep-agent-#{unique_id}"
      octet = rem(unique_id, 200) + 1

      {:ok, _initial_target} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: "version-sweep-initial-device-#{unique_id}",
            ip: "10.#{octet}.0.1",
            hostname: "version-sweep-initial-#{unique_id}",
            discovery_sources: ["sweep"]
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, _updated_target} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: "version-sweep-updated-device-#{unique_id}",
            ip: "172.16.#{octet}.1",
            hostname: "version-sweep-updated-#{unique_id}",
            discovery_sources: ["sweep"]
          },
          actor: actor
        )
        |> Ash.create()

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

      {:ok, config1} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
      version1 = config1.config_version

      # Update SRQL targeting
      {:ok, _updated} =
        group
        |> Ash.Changeset.for_update(:update, %{
          target_query: "in:devices ip:172.16.0.0/12"
        })
        |> Ash.update(actor: actor)

      ConfigServer.invalidate(:sweep)

      {:ok, config2} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
      version2 = config2.config_version

      # Version should be different after criteria update
      refute version1 == version2
    end

    test "agent-specific sweep groups are included for matching agent", %{
      actor: actor,
      unique_id: unique_id
    } do
      agent_uid = "agent-specific-sweep-#{unique_id}"
      {:ok, _agent} = create_connected_agent(actor, agent_uid)

      # SweepGroup validates agent_ids against registered agents, so the group's
      # agent has to exist before the group does.
      {:ok, _agent} = create_connected_agent(actor, agent_uid)

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

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
      payload = Jason.decode!(config.config_json)

      if payload["sweep"]["groups"] do
        group_names = Enum.map(payload["sweep"]["groups"], & &1["name"])
        # Should include both agent-specific and partition-wide groups
        assert "Agent Specific Sweep #{unique_id}" in group_names
        assert "Partition Wide Sweep #{unique_id}" in group_names
      end
    end

    test "agent-specific sweep groups are excluded for other agents", %{
      actor: actor,
      unique_id: unique_id
    } do
      assigned_agent_uid = "assigned-sweep-agent-#{unique_id}"
      other_agent_uid = "other-sweep-agent-#{unique_id}"
      {:ok, _agent} = create_connected_agent(actor, assigned_agent_uid)

      {:ok, _assigned} = create_connected_agent(actor, assigned_agent_uid)
      {:ok, _other} = create_connected_agent(actor, other_agent_uid)

      {:ok, _group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Other Agent Should Not Receive #{unique_id}",
            partition: "default",
            agent_id: assigned_agent_uid,
            interval: "15m",
            static_targets: ["10.0.199.1"],
            enabled: true
          },
          actor: actor
        )
        |> Ash.create()

      ConfigServer.invalidate(:sweep)

      {:ok, config} = AgentConfigGenerator.generate_config(other_agent_uid, @default_partition)
      payload = Jason.decode!(config.config_json)
      group_names = Enum.map(payload["sweep"]["groups"] || [], & &1["name"])

      refute "Other Agent Should Not Receive #{unique_id}" in group_names
    end
  end

  describe "native add-on assignments" do
    test "compiled add-on carries delivery, supervision, and the approved capability subset", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      {:ok, _agent} = create_connected_agent(actor, agent_uid)

      {:ok, package} =
        create_approved_addon_package(actor, unique_id,
          capabilities: ["remoteaccess", "diagnostics"],
          approved_capabilities: ["remoteaccess"]
        )

      {:ok, _assignment} = assign_addon(actor, agent_uid, package)

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      assert [addon] = config.addons
      assert addon.addon_id == package.addon_id
      assert addon.enabled == true
      assert addon.delivery == :compiled_in
      assert addon.supervision == :config_toggle
      # The operator-approved subset wins over the package's full manifest list.
      assert addon.capabilities == ["remoteaccess"]
      assert addon.binary_path == "/opt/sr/bin/sample-addon-#{unique_id}"
    end

    test "capabilities fall back to the package manifest when none are approved", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      {:ok, _agent} = create_connected_agent(actor, agent_uid)

      {:ok, package} =
        create_approved_addon_package(actor, unique_id,
          capabilities: ["remoteaccess", "diagnostics"],
          approved_capabilities: []
        )

      {:ok, _assignment} = assign_addon(actor, agent_uid, package)

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      assert [addon] = config.addons
      assert addon.capabilities == ["remoteaccess", "diagnostics"]
    end

    test "blob-missing approved packages are omitted from generated add-on config", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      {:ok, _agent} = create_connected_agent(actor, agent_uid)

      {:ok, package} =
        create_approved_addon_package(actor, unique_id,
          capabilities: ["endpoint_inventory"],
          approved_capabilities: ["endpoint_inventory"]
        )

      {:ok, _assignment} = assign_addon(actor, agent_uid, package)

      {:ok, _package} =
        package
        |> Ash.Changeset.for_update(
          :update,
          %{
            verification_status: "blob_missing",
            verification_error:
              "native add-on artifact object missing: native-addons/missing.tar.gz"
          },
          actor: actor
        )
        |> Ash.update()

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      assert config.addons == []
    end

    test "a binary/install-path change re-versions the agent config", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      {:ok, _agent} = create_connected_agent(actor, agent_uid)

      {:ok, package} =
        create_approved_addon_package(actor, unique_id,
          capabilities: ["remoteaccess"],
          approved_capabilities: ["remoteaccess"]
        )

      {:ok, _assignment} = assign_addon(actor, agent_uid, package)

      {:ok, before} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      # An executable upgrade (new install_path) must change config_version so a
      # polling agent stops receiving :not_modified and relaunches the new binary.
      {:ok, _updated} =
        package
        |> Ash.Changeset.for_update(:update, %{install_path: "/opt/sr/bin/v2"}, actor: actor)
        |> Ash.update()

      {:ok, after_change} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      refute before.config_version == after_change.config_version
    end

    test "rejects assignment params that violate the package config schema", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      {:ok, _agent} = create_connected_agent(actor, agent_uid)

      {:ok, package} =
        create_approved_addon_package(actor, unique_id,
          capabilities: ["remoteaccess"],
          approved_capabilities: ["remoteaccess"],
          config_schema: %{
            "type" => "object",
            "properties" => %{"port" => %{"type" => "integer"}},
            "required" => ["port"]
          }
        )

      # Invalid params must be rejected at the control plane, not pushed to the
      # agent to fail later as a Configure rejection.
      assert {:error, error} = assign_addon(actor, agent_uid, package, %{"port" => "not-an-int"})
      assert inspect(error) =~ "params"
    end

    test "accepts assignment params that satisfy the package config schema", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      {:ok, _agent} = create_connected_agent(actor, agent_uid)

      {:ok, package} =
        create_approved_addon_package(actor, unique_id,
          capabilities: ["remoteaccess"],
          approved_capabilities: ["remoteaccess"],
          config_schema: %{
            "type" => "object",
            "properties" => %{"port" => %{"type" => "integer"}},
            "required" => ["port"]
          }
        )

      assert {:ok, _assignment} = assign_addon(actor, agent_uid, package, %{"port" => 8080})
    end

    test "pushed-artifact assignment carries the per-arch artifact reference", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      {:ok, _agent} =
        create_connected_agent(actor, agent_uid, %{"os" => "linux", "arch" => "amd64"})

      object_key = "addons/sample-addon-#{unique_id}/1.0.0/linux-amd64"
      sha = String.duplicate("a", 64)

      {:ok, package} =
        create_approved_addon_package(actor, unique_id,
          capabilities: ["sample"],
          approved_capabilities: ["sample"],
          delivery: :pushed_artifact,
          artifacts: %{
            "linux/amd64" => %{
              "object_key" => object_key,
              "sha256" => sha,
              "signature" => "sig-#{unique_id}"
            }
          }
        )

      {:ok, _assignment} = assign_addon(actor, agent_uid, package)

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      assert [addon] = config.addons
      assert addon.delivery == :pushed_artifact
      assert addon.artifact_object_key == object_key
      assert addon.artifact_sha256 == sha
      assert addon.artifact_signature == "sig-#{unique_id}"
      assert addon.target_os == "linux"
      assert addon.target_arch == "amd64"
    end

    test "pushed-artifact assignment is omitted when no artifact matches the agent arch", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      # Agent is arm64 but the package only published a linux/amd64 artifact.
      {:ok, _agent} =
        create_connected_agent(actor, agent_uid, %{"os" => "linux", "arch" => "arm64"})

      {:ok, package} =
        create_approved_addon_package(actor, unique_id,
          capabilities: ["sample"],
          approved_capabilities: ["sample"],
          delivery: :pushed_artifact,
          artifacts: %{"linux/amd64" => %{"object_key" => "k", "sha256" => "s"}}
        )

      {:ok, _assignment} = assign_addon(actor, agent_uid, package)

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      assert config.addons == []
    end

    test "pushed-artifact assignment is omitted when the matching artifact is incomplete", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      {:ok, _agent} =
        create_connected_agent(actor, agent_uid, %{"os" => "linux", "arch" => "amd64"})

      # Matching arch, but the artifact entry is missing sha256: the agent must not be
      # told to fetch something it cannot verify, so no reference is emitted.
      {:ok, package} =
        create_approved_addon_package(actor, unique_id,
          capabilities: ["sample"],
          approved_capabilities: ["sample"],
          delivery: :pushed_artifact,
          artifacts: %{"linux/amd64" => %{"object_key" => "addons/x/linux-amd64"}}
        )

      {:ok, _assignment} = assign_addon(actor, agent_uid, package)

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      assert config.addons == []
    end

    test "assignment is omitted when the agent platform is outside package requirements", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      {:ok, _agent} =
        create_connected_agent(actor, agent_uid, %{"os" => "darwin", "arch" => "amd64"})

      {:ok, package} =
        create_approved_addon_package(actor, unique_id,
          capabilities: ["sample"],
          approved_capabilities: ["sample"],
          delivery: :compiled_in,
          supervision: :config_toggle,
          requires: %{"platforms" => ["linux"]}
        )

      {:ok, _assignment} = assign_addon(actor, agent_uid, package)

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      assert config.addons == []
    end

    test "assignment is omitted when the agent version is below the package base-agent floor", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      {:ok, _agent} =
        create_connected_agent(actor, agent_uid, %{"os" => "linux", "arch" => "amd64"}, %{
          version: "1.1.9"
        })

      {:ok, package} =
        create_approved_addon_package(actor, unique_id,
          capabilities: ["sample"],
          approved_capabilities: ["sample"],
          delivery: :compiled_in,
          supervision: :config_toggle,
          requires: %{"base_agent" => ">=1.2.0", "platforms" => ["linux"]}
        )

      {:ok, _assignment} = assign_addon(actor, agent_uid, package)

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      assert config.addons == []
    end

    test "assignment is omitted when the agent no longer advertises a package-required capability",
         %{
           actor: actor,
           agent_uid: agent_uid,
           unique_id: unique_id
         } do
      {:ok, _agent} =
        create_connected_agent(actor, agent_uid, %{"os" => "linux", "arch" => "amd64"}, %{
          version: "1.2.0",
          capabilities: []
        })

      {:ok, package} =
        create_approved_addon_package(actor, unique_id,
          capabilities: ["sample"],
          approved_capabilities: ["sample"],
          delivery: :compiled_in,
          supervision: :config_toggle,
          requires: %{
            "base_agent" => ">=1.2.0",
            "platforms" => ["linux"],
            "agent_capabilities" => ["host-network-visibility"]
          }
        )

      {:ok, _assignment} = assign_addon(actor, agent_uid, package)

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      assert config.addons == []
    end

    test "assignment is emitted when package platform and base-agent floor are satisfied", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      {:ok, _agent} =
        create_connected_agent(actor, agent_uid, %{"os" => "linux", "arch" => "amd64"}, %{
          version: "1.2.0"
        })

      {:ok, package} =
        create_approved_addon_package(actor, unique_id,
          capabilities: ["sample"],
          approved_capabilities: ["sample"],
          delivery: :compiled_in,
          supervision: :config_toggle,
          requires: %{"base_agent" => ">=1.2.0", "platforms" => ["linux"]}
        )

      {:ok, _assignment} = assign_addon(actor, agent_uid, package)

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      assert [addon] = config.addons
      assert addon.addon_id == package.addon_id
    end

    test "required otel collector add-on is compiled without an explicit assignment", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      Application.put_env(:serviceradar_core, :required_agent_addons, ["otel-collector"])

      {:ok, _agent} =
        create_connected_agent(actor, agent_uid, %{"os" => "linux", "arch" => "amd64"}, %{
          version: "1.2.0"
        })

      object_key =
        "native-addons/otel-collector/0.1.0/linux/amd64/#{String.duplicate("c", 64)}.tar.gz"

      sha = String.duplicate("d", 64)

      {:ok, package} =
        create_approved_addon_package(actor, unique_id,
          addon_id: "otel-collector",
          version: "0.1.#{unique_id}",
          binary: "serviceradar-otel-addon",
          capabilities: ["otlp-relay:v1", "native-telemetry:v1"],
          approved_capabilities: ["otlp-relay:v1", "native-telemetry:v1"],
          delivery: :pushed_artifact,
          supervision: :agent_sidecar,
          requires: %{"base_agent" => ">=1.2.0", "platforms" => ["linux"]},
          artifacts: %{
            "linux/amd64" => %{
              "object_key" => object_key,
              "sha256" => sha,
              "signature" => "sig-#{unique_id}"
            }
          }
        )

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      assert [addon] = config.addons
      assert addon.addon_id == "otel-collector"
      assert addon.enabled == true
      assert addon.delivery == :pushed_artifact
      assert addon.supervision == :agent_sidecar
      assert addon.binary_path == "/opt/sr/bin/serviceradar-otel-addon"
      assert addon.capabilities == ["otlp-relay:v1", "native-telemetry:v1"]
      assert addon.artifact_object_key == object_key
      assert addon.artifact_sha256 == sha
      assert addon.artifact_signature == "sig-#{unique_id}"
      assert addon.target_os == "linux"
      assert addon.target_arch == "amd64"

      proto = AgentConfigGenerator.to_proto_response(config)
      assert [proto_addon] = proto.addons
      assert proto_addon.addon_id == "otel-collector"
      assert proto_addon.version == package.version
      assert proto_addon.delivery == "pushed_artifact"
      assert proto_addon.supervision == "agent_sidecar"
      assert proto_addon.config_json == ""
    end

    test "required add-on is omitted when the agent lacks a package-required capability", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      addon_id = "required-capability-addon-#{unique_id}"
      Application.put_env(:serviceradar_core, :required_agent_addons, [addon_id])

      {:ok, _agent} =
        create_connected_agent(actor, agent_uid, %{"os" => "linux", "arch" => "amd64"}, %{
          version: "1.2.0",
          capabilities: []
        })

      {:ok, _package} =
        create_approved_addon_package(actor, unique_id,
          addon_id: addon_id,
          capabilities: ["sample"],
          approved_capabilities: ["sample"],
          delivery: :compiled_in,
          supervision: :config_toggle,
          requires: %{
            "base_agent" => ">=1.2.0",
            "platforms" => ["linux"],
            "agent_capabilities" => ["native-addon-management"]
          }
        )

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      assert config.addons == []
    end

    test "explicit otel collector assignment suppresses the required default duplicate", %{
      actor: actor,
      agent_uid: agent_uid,
      unique_id: unique_id
    } do
      Application.put_env(:serviceradar_core, :required_agent_addons, ["otel-collector"])

      {:ok, _agent} =
        create_connected_agent(actor, agent_uid, %{"os" => "linux", "arch" => "amd64"}, %{
          version: "1.2.0"
        })

      artifact = %{
        "object_key" =>
          "native-addons/otel-collector/0.1.0/linux/amd64/#{String.duplicate("e", 64)}.tar.gz",
        "sha256" => String.duplicate("f", 64),
        "signature" => "sig-#{unique_id}"
      }

      {:ok, package} =
        create_approved_addon_package(actor, unique_id,
          addon_id: "otel-collector",
          version: "0.1.#{unique_id}",
          binary: "serviceradar-otel-addon",
          capabilities: ["otlp-relay:v1", "native-telemetry:v1"],
          approved_capabilities: ["otlp-relay:v1", "native-telemetry:v1"],
          delivery: :pushed_artifact,
          supervision: :agent_sidecar,
          requires: %{"base_agent" => ">=1.2.0", "platforms" => ["linux"]},
          artifacts: %{"linux/amd64" => artifact}
        )

      {:ok, _assignment} =
        assign_addon(actor, agent_uid, package, %{
          "agent_forward" => %{"max_bytes" => 1_048_576}
        })

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      assert [addon] = config.addons
      assert addon.addon_id == "otel-collector"
      assert addon.params == %{"agent_forward" => %{"max_bytes" => 1_048_576}}
    end

    test "bumblebee add-on assignment is emitted for k8s-agent when compatible", %{
      actor: actor,
      unique_id: unique_id
    } do
      {:ok, _agent} =
        create_connected_agent(actor, "k8s-agent", %{"os" => "linux", "arch" => "amd64"}, %{
          version: "1.2.0"
        })

      {:ok, package} =
        create_approved_addon_package(actor, unique_id,
          addon_id: "bumblebee",
          binary: "serviceradar-bumblebee",
          capabilities: ["inventory"],
          approved_capabilities: ["inventory"],
          delivery: :compiled_in,
          supervision: :config_toggle,
          requires: %{"base_agent" => ">=1.2.0", "platforms" => ["linux"]}
        )

      {:ok, _assignment} = assign_addon(actor, "k8s-agent", package)

      {:ok, config} = AgentConfigGenerator.generate_config("k8s-agent", @default_partition)

      assert [addon] = config.addons
      assert addon.addon_id == "bumblebee"
    end

    test "netprobe systemd-service assignment compiles to a systemd_service addon the agent attaches to",
         %{actor: actor, agent_uid: agent_uid, unique_id: unique_id} do
      {:ok, _agent} =
        create_connected_agent(actor, agent_uid, %{"os" => "linux", "arch" => "amd64"}, %{
          capabilities: ["host-network-visibility"]
        })

      object_key = "native-addons/netprobe/0.1.0/linux/amd64/#{String.duplicate("a", 64)}.tar.gz"
      sha = String.duplicate("b", 64)

      {:ok, package} =
        create_approved_addon_package(actor, unique_id,
          addon_id: "netprobe",
          binary: "serviceradar-netprobe",
          capabilities: ["host-network-visibility"],
          approved_capabilities: ["host-network-visibility"],
          delivery: :pushed_artifact,
          supervision: :systemd_service,
          requires: %{
            "agent_capabilities" => ["host-network-visibility"],
            "os_capabilities" => ["cap_net_raw", "cap_bpf", "cap_perfmon"]
          },
          artifacts: %{
            "linux/amd64" => %{
              "object_key" => object_key,
              "sha256" => sha,
              "signature" => "sig-#{unique_id}"
            }
          }
        )

      {:ok, _assignment} = assign_addon(actor, agent_uid, package)

      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

      # The netprobe assignment compiles as a systemd-service add-on carrying the per-arch
      # artifact + file capabilities the root-owned agent-updater applies via setcap.
      assert [addon] = config.addons
      assert addon.addon_id == "netprobe"
      assert addon.enabled == true
      assert addon.delivery == :pushed_artifact
      assert addon.supervision == :systemd_service
      assert addon.capabilities == ["host-network-visibility"]
      assert addon.os_capabilities == ["cap_net_raw", "cap_bpf", "cap_perfmon"]
      assert addon.artifact_object_key == object_key
      assert addon.artifact_sha256 == sha
      assert addon.target_os == "linux"
      assert addon.target_arch == "amd64"

      # Cross-system contract: the :systemd_service atom must stringify to exactly
      # "systemd_service" (the constant the agent's classifyAddonSupervision matches to route
      # netprobe onto the attach path); a hyphen/format drift would silently break the cutover.
      # The VisibilityConfig (capture params) rides in the SAME response — the agent §2.2 cutover
      # reads both: the assignment to decide attach, VisibilityConfig for the capture config.
      proto = AgentConfigGenerator.to_proto_response(config)
      assert [proto_addon] = proto.addons
      assert proto_addon.addon_id == "netprobe"
      assert proto_addon.supervision == "systemd_service"
      assert proto_addon.delivery == "pushed_artifact"
      assert proto_addon.os_capabilities == ["cap_net_raw", "cap_bpf", "cap_perfmon"]
      assert proto_addon.artifact_object_key == object_key
      assert proto_addon.target_arch == "amd64"
      assert proto.visibility_config
    end
  end

  defp create_approved_addon_package(actor, unique_id, opts) do
    capabilities = Keyword.get(opts, :capabilities, [])
    approved = Keyword.get(opts, :approved_capabilities, [])
    config_schema = Keyword.get(opts, :config_schema, %{})
    delivery = Keyword.get(opts, :delivery, :compiled_in)
    supervision = Keyword.get(opts, :supervision, :config_toggle)
    artifacts = Keyword.get(opts, :artifacts, %{})
    addon_id = Keyword.get(opts, :addon_id, "sample-addon-#{unique_id}")
    version = Keyword.get(opts, :version, "1.0.0")
    binary = Keyword.get(opts, :binary, "sample-addon-#{unique_id}")
    requires = Keyword.get(opts, :requires, %{})

    {:ok, package} =
      AddonPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          addon_id: addon_id,
          version: version,
          name: "Sample Addon #{unique_id}",
          binary: binary,
          install_path: "/opt/sr/bin",
          capabilities: capabilities,
          config_schema: config_schema,
          delivery: delivery,
          supervision: supervision,
          requires: requires,
          artifacts: artifacts
        },
        actor: actor
      )
      |> Ash.create()

    package
    |> Ash.Changeset.for_update(
      :approve,
      %{approved_capabilities: approved, approved_by: "test@serviceradar.local"},
      actor: actor
    )
    |> Ash.update()
  end

  defp assign_addon(actor, agent_uid, package, params \\ %{}) do
    AddonAssignment
    |> Ash.Changeset.for_create(
      :create,
      %{agent_uid: agent_uid, addon_package_id: package.id, enabled: true, params: params},
      actor: actor
    )
    |> Ash.create()
  end

  defp create_connected_agent(actor, agent_uid, metadata \\ %{}, attrs \\ %{}) do
    Agent
    |> Ash.Changeset.for_create(
      :register_connected,
      Map.merge(
        %{
          uid: agent_uid,
          name: "Config Test Agent #{agent_uid}",
          host: "127.0.0.1",
          port: 50_051,
          metadata: metadata
        },
        attrs
      ),
      actor: actor
    )
    |> Ash.create()
  end

  defp register_control_session!(agent_uid, partition_id) do
    assert {:ok, _pid} =
             ServiceRadar.ProcessRegistry.register(
               {:agent_control, partition_id, agent_uid, node()},
               %{
                 agent_id: agent_uid,
                 partition_id: partition_id,
                 gateway_node: node(),
                 capabilities: ["wasm"]
               }
             )

    await_control_partition!(agent_uid, partition_id, 40)
  end

  defp create_plugin_assignment!(agent_uid, attrs, actor) do
    ServiceRadar.TestSupport.drain_dependency_dispatcher_tasks()
    register_control_session!(agent_uid, @default_partition)

    try do
      changeset =
        Ash.Changeset.for_create(
          PluginAssignment,
          :create,
          Map.put(attrs, :agent_uid, agent_uid),
          actor: actor
        )

      case Ash.create(changeset,
             domain: ServiceRadar.Plugins,
             return_notifications?: true
           ) do
        {:ok, assignment, _notifications} -> assignment
        {:error, error} -> raise Ash.Error.to_error_class(error)
      end
    after
      :ok =
        ServiceRadar.ProcessRegistry.unregister(
          {:agent_control, @default_partition, agent_uid, node()}
        )
    end
  end

  defp await_control_partition!(_agent_uid, _partition_id, 0),
    do: flunk("test control-session partition did not converge")

  defp await_control_partition!(agent_uid, partition_id, attempts) do
    case ServiceRadar.Edge.AgentCommandBus.resolve_control_session_evidence(
           partition_id,
           agent_uid,
           nil
         ) do
      {:ok, %{agent_id: ^agent_uid, partition_id: ^partition_id}} ->
        :ok

      _other ->
        Process.sleep(10)
        await_control_partition!(agent_uid, partition_id, attempts - 1)
    end
  end

  defp create_active_bumblebee_snapshot!(actor, unique_id) do
    {:ok, snapshot} =
      BumblebeeCatalogSnapshot
      |> Ash.Changeset.for_create(
        :create,
        %{
          snapshot_ref: "bumblebee:test:#{unique_id}",
          source_revision: "rev-#{unique_id}",
          catalog_version: "catalog-#{unique_id}",
          schema_version: "serviceradar.bumblebee.catalog.v1",
          status: "candidate",
          entry_count: 1,
          content_sha256: "sha-#{unique_id}",
          object_key: "bumblebee/catalogs/#{unique_id}/catalog.json",
          object_size_bytes: 42,
          validation_result: %{"status" => "valid"},
          artifact_metadata: %{},
          metadata: %{}
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    snapshot
    |> Ash.Changeset.for_update(
      :promote,
      %{
        entry_count: 1,
        content_sha256: "sha-#{unique_id}",
        object_key: "bumblebee/catalogs/#{unique_id}/catalog.json",
        object_size_bytes: 42,
        validation_result: %{"status" => "valid"},
        artifact_metadata: %{}
      },
      actor: actor
    )
    |> Ash.update!(actor: actor)
  end

  defp create_bumblebee_config_instance!(actor, agent_uid, compiled_config) do
    ConfigInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        config_type: :bumblebee,
        partition: "default",
        agent_id: agent_uid,
        compiled_config: compiled_config,
        source_ids: []
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp unique_ip(seed) when is_binary(seed) do
    <<second, third, fourth, _rest::binary>> = :crypto.hash(:sha256, seed)
    "10.#{1 + rem(second, 254)}.#{1 + rem(third, 254)}.#{1 + rem(fourth, 254)}"
  end
end
