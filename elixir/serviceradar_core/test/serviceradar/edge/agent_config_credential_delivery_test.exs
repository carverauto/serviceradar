defmodule ServiceRadar.Edge.AgentConfigCredentialDeliveryTest do
  @moduledoc """
  DB-backed coverage for credential-broker grant materialization at agent
  config delivery time (tasks 3.2/3.3, refactor-device-identity-reconciliation).

  A policy plugin assignment whose embedded broker grant has expired must be
  delivered with (a) a freshly re-minted grant payload, (b) the resolved
  `api_token` runtime material retained only in the trusted agent-host envelope,
  and (c) a `credential_secret_resolution_audits` row per resolution — while
  keeping the config version hash stable so polling agents are not relaunched
  every generation.
  """

  # Serial: the registered control session makes this agent a push target for
  # every other test's config dispatch, and those pushes regenerate its config
  # under their own sandbox into the application-wide ConfigCache, which the
  # version-stability assertions below then read.
  use ServiceRadar.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compiler
  alias ServiceRadar.AgentConfig.ConfigCache
  alias ServiceRadar.AgentConfig.ConfigServer
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.CredentialSecretResolutionAudit
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Edge.AgentGatewaySync
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.VirtualizationHost
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.Repo
  alias ServiceRadar.SNMPProfiles.SNMPProfile

  # The real shipped manifest, not a stand-in. Its `additionalProperties: false`
  # is what made a materialized Proxmox assignment unstorable, and with the
  # fixture's previous `config_schema: %{}` this suite proved nothing about it:
  # an empty schema short-circuits AssignmentParams to :ok.
  @proxmox_config_schema "../../../../../go/cmd/wasm-plugins/proxmox/config.schema.json"
                         |> Path.expand(__DIR__)
                         |> File.read!()
                         |> Jason.decode!()

  @moduletag :integration

  @api_token_payload "root@pam!sr-inventory=abc123-secret"
  @rotated_api_token_payload "root@pam!sr-inventory=rotated-secret"
  @awx_host_credential_sentinel "__SERVICERADAR_AWX_INVENTORY_HOST_CREDENTIAL__"
  @default_partition "default"

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    unique_id = :erlang.unique_integer([:positive])

    admin = %{
      id: Ash.UUID.generate(),
      email: "credential-delivery-test@serviceradar.local",
      role: :admin
    }

    system = SystemActor.system(:credential_delivery_test)
    agent_uid = "cred-delivery-agent-#{unique_id}"
    register_control_session!(agent_uid, @default_partition)

    {:ok, admin: admin, system: system, agent_uid: agent_uid, unique_id: unique_id}
  end

  test "host-only tokens are fingerprinted in the version projection and rotate its hash" do
    assignment = %{
      assignment_id: "awx-version-projection",
      params: %{
        "controllers" => [
          %{
            "controller_id" => "awx-a",
            "base_url" => "https://awx-a.example.invalid",
            "api_token" => @awx_host_credential_sentinel
          }
        ]
      },
      host_params: %{
        "schema" => "serviceradar.awx_inventory_host_credentials.v1",
        "controllers" => [
          %{
            "controller_id" => "awx-a",
            "base_url" => "https://awx-a.example.invalid",
            "api_token" => @api_token_payload,
            "insecure_skip_verify" => false
          }
        ]
      },
      download_token: "volatile-download-token"
    }

    rotated_assignment =
      put_in(
        assignment,
        [:host_params, "controllers", Access.at(0), "api_token"],
        @rotated_api_token_payload
      )

    projection = AgentConfigGenerator.plugin_assignment_version_projection(assignment)

    rotated_projection =
      AgentConfigGenerator.plugin_assignment_version_projection(rotated_assignment)

    expected_fingerprint =
      "sha256:" <>
        Base.encode16(:crypto.hash(:sha256, @api_token_payload), case: :lower)

    assert get_in(projection, [:host_params, "controllers", Access.at(0), "api_token"]) ==
             expected_fingerprint

    refute Jason.encode!(projection) =~ @api_token_payload
    refute Map.has_key?(projection, :download_token)

    version = Compiler.content_hash(%{plugins: [projection]})
    rotated_version = Compiler.content_hash(%{plugins: [rotated_projection]})
    refute version == rotated_version
  end

  test "expired policy broker grant is re-minted, resolved to api_token, and audited",
       %{admin: admin, system: system, agent_uid: agent_uid, unique_id: unique_id} do
    {:ok, _agent} = create_connected_agent(admin, agent_uid)
    package = create_approved_plugin_package!(admin, unique_id, @proxmox_config_schema)
    secret = create_proxmox_secret!(admin, unique_id)
    stale_grant = issue_expired_grant!(system, secret, agent_uid)
    stale_payload = CredentialBrokerGrant.to_payload(stale_grant)

    assert {:ok, stale_expiry, _offset} = DateTime.from_iso8601(stale_payload["expires_at"])
    assert DateTime.before?(stale_expiry, DateTime.utc_now())

    _assignment =
      PluginAssignment
      |> Ash.Changeset.for_create(
        :create,
        %{
          agent_uid: agent_uid,
          plugin_package_id: package.id,
          source: :policy,
          source_key: "policy-key-#{unique_id}",
          policy_id: "network-credential-rule:rule-#{unique_id}",
          enabled: true,
          interval_seconds: 300,
          timeout_seconds: 30,
          params: %{
            "schema" => "serviceradar.plugin_inputs.v1",
            "policy_id" => "network-credential-rule:rule-#{unique_id}",
            "policy_version" => 1,
            "agent_id" => agent_uid,
            "generated_at" => DateTime.to_iso8601(DateTime.utc_now()),
            "inputs" => [
              %{
                "name" => "targets",
                "entity" => "devices",
                "query" => "in:devices vendor:proxmox",
                "chunk_index" => 0,
                "chunk_total" => 1,
                "chunk_hash" => String.duplicate("a", 64),
                "items" => [%{"ip" => "10.0.2.4", "hostname" => "pve01"}]
              }
            ],
            "template" => %{
              "credential_broker" => stale_payload,
              "api_token_secret_ref" => SecretRefs.network_credential_ref(to_string(secret.id)),
              "timeout_ms" => 30_000
            }
          }
        },
        actor: system
      )
      |> create_without_notifications!()

    {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

    assert [plugin] = config.plugins
    template = plugin.params["template"]

    # (a) the plugin receives usable api_token material, not just a ref
    assert template["api_token"] == @api_token_payload
    refute Map.has_key?(template, "_secret_material")

    # (b) the delivered grant payload was re-minted: never expired material
    delivered = template["credential_broker"]
    assert delivered["grant_id"] != to_string(stale_grant.id)
    assert {:ok, delivered_expiry, _offset} = DateTime.from_iso8601(delivered["expires_at"])
    assert DateTime.after?(delivered_expiry, DateTime.utc_now())
    assert delivered["credential_secret_ref"] == stale_payload["credential_secret_ref"]

    # (c) the resolution wrote an audit row tied to the re-minted grant
    assert {:ok, audits} =
             CredentialSecretResolutionAudit.list_for_secret(secret.id, actor: system)

    assert [audit | _] = audits
    assert audit.outcome == :success
    assert audit.grant_id == delivered["grant_id"]
    assert audit.consumer_kind == :plugin
    assert audit.agent_id == agent_uid
    assert audit.resolution_location == :agent

    # Refresh-on-expiry must not destabilize the config version: each
    # generation re-mints a short-TTL grant, and the rotating payload is
    # excluded from the version hash (like download tokens).
    {:ok, config2} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
    assert config.config_version == config2.config_version

    delivered2 =
      config2.plugins |> hd() |> Map.fetch!(:params) |> get_in(["template", "credential_broker"])

    assert delivered2["grant_id"] != to_string(stale_grant.id)

    # one audit row per resolution
    assert {:ok, audits_after} =
             CredentialSecretResolutionAudit.list_for_secret(secret.id, actor: system)

    assert length(audits_after) > length(audits) - 1
    assert length(audits_after) >= 2
  end

  # A generation's SNMP section can be compiled by another process whose
  # database reads fail: a config push on a broken connection, or in the test
  # sandbox a pusher whose owner exited mid-generation. That compile used to
  # report the failed default-profile read as "no profile", and ConfigServer
  # cached the resulting disabled fragment under this agent's key, so the next
  # generation hashed it and returned a new config_version with nothing changed.
  test "an SNMP section compiled with failing reads does not re-version the config",
       %{admin: admin, system: system, agent_uid: agent_uid, unique_id: unique_id} do
    default_snmp = default_snmp_profile!(system)
    {:ok, _agent} = create_connected_agent(admin, agent_uid)
    create_expired_grant_policy_assignment!(admin, system, agent_uid, unique_id)

    {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
    assert config.snmp_config.profile_id == to_string(default_snmp.id)

    ConfigCache.invalidate(:snmp)
    failed_section = compile_snmp_section_with_failing_reads(agent_uid)

    {:ok, config2} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
    assert config.config_version == config2.config_version
    assert config2.snmp_config.profile_id == to_string(default_snmp.id)
    # The failed read surfaced as an error rather than as a cacheable config.
    refute match?({:ok, _entry}, failed_section)

    # A real SNMP change still re-versions the config.
    {:ok, _renamed} =
      default_snmp
      |> Ash.Changeset.for_update(:update, %{name: "Default SNMP #{unique_id}"}, actor: system)
      |> Ash.update(actor: system)

    ConfigCache.invalidate(:snmp)
    {:ok, config3} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
    assert config3.snmp_config.profile_name == "Default SNMP #{unique_id}"
    refute config3.config_version == config2.config_version
  end

  test "consecutive generations reuse one live broker grant and keep one config version",
       %{admin: admin, system: system, agent_uid: agent_uid, unique_id: unique_id} do
    {:ok, _agent} = create_connected_agent(admin, agent_uid)
    create_expired_grant_policy_assignment!(admin, system, agent_uid, unique_id)

    configs =
      for generation <- 1..4 do
        # Second-resolution timestamps (grant issued_at/expires_at) differ
        # between every pair of generations.
        if generation > 1, do: cross_second_boundary()
        {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
        config
      end

    delivered_grant_ids =
      Enum.map(configs, fn config ->
        config.plugins |> hd() |> get_in([:params, "template", "credential_broker", "grant_id"])
      end)

    # The stored grant is expired, so the first generation issues one; every
    # later generation delivers that live grant instead of minting another.
    assert [_one] = Enum.uniq(delivered_grant_ids)
    assert configs |> Enum.map(& &1.config_version) |> Enum.uniq() |> length() == 1
  end

  test "an agent that resolves by binding gets grant scope only and core issues the grant at use",
       %{admin: admin, system: system, agent_uid: agent_uid} do
    {:ok, _agent} =
      create_connected_agent(admin, agent_uid, ["credential_broker_resolve_by_binding"])

    secret = create_proxmox_secret!(admin, System.unique_integer([:positive]))
    rule = create_proxmox_inventory_rule!(system, secret, agent_uid)
    assignment_id = insert_proxmox_inventory_assignment!(rule, secret, agent_uid)

    {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
    assert [plugin] = config.plugins
    assert [binding] = plugin.host_params["bindings"]
    refute Map.has_key?(binding["credential_broker"], "grant_id")
    refute Map.has_key?(binding["credential_broker"], "expires_at")
    assert grant_count(secret) == 0

    request = %{
      agent_id: agent_uid,
      assignment_id: assignment_id,
      binding_id: binding["binding_id"],
      consumer_kind: "plugin",
      consumer_id: "proxmox-inventory",
      purpose: "inventory_enrichment",
      resolution_location: "agent"
    }

    assert {:ok, %{value: @api_token_payload}} =
             AgentGatewaySync.resolve_credential_broker_grant(request)

    assert {:ok, %{value: @api_token_payload}} =
             AgentGatewaySync.resolve_credential_broker_grant(request)

    assert grant_count(secret) == 1

    {:ok, config_after} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
    assert config_after.config_version == config.config_version

    for {label, denied_request} <- [
          {"another agent", %{request | agent_id: agent_uid <> "-other"}},
          {"an unknown binding", %{request | binding_id: "unknown-binding"}}
        ] do
      assert {:error, _reason} = AgentGatewaySync.resolve_credential_broker_grant(denied_request),
             "#{label} resolved the binding"
    end

    # The rule now names another secret: the assignment still references the
    # old one, so the issue guard refuses and nothing is reused.
    replacement = create_proxmox_secret!(admin, System.unique_integer([:positive]))

    assert {:ok, rule} =
             rule
             |> Ash.Changeset.for_update(:update, %{secret_id: replacement.id}, actor: system)
             |> Ash.update()

    assert {:error, _reason} = AgentGatewaySync.resolve_credential_broker_grant(request)

    assert {:ok, _rule} =
             rule
             |> Ash.Changeset.for_update(:update, %{enabled: false}, actor: system)
             |> Ash.update()

    assert {:error, _reason} = AgentGatewaySync.resolve_credential_broker_grant(request)
    assert grant_count(secret) == 1
    assert grant_count(replacement) == 0
    # another agent, the changed secret and the disabled rule; the unknown
    # binding is audited under its own id
    assert binding_denials(binding["binding_id"]) == 3
  end

  # An interactive console session completes a virtualization row that predates
  # the v3 identity contract from its credential rule's source scope. Config
  # delivery must complete it from the assignment's own rule the same way;
  # without that scope the item fails to resolve and the whole console
  # assignment is withheld from the agent.
  test "a console assignment completes a legacy PVE host row from its credential-rule scope",
       %{admin: admin, system: system, agent_uid: agent_uid} do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    {:ok, _agent} =
      create_connected_agent(admin, agent_uid, ["credential_broker_resolve_by_binding"])

    secret = create_proxmox_secret!(admin, System.unique_integer([:positive]))
    rule = create_proxmox_console_rule!(system, secret, agent_uid)
    missing_device_uid = "sr:device:missing-pve-#{System.unique_integer([:positive])}"

    stale_assignment_id =
      insert_proxmox_console_assignment!(rule, secret, agent_uid, missing_device_uid)

    first_skip_log =
      capture_log([level: :debug], fn ->
        {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
        assert config.plugins == []
      end)

    assert first_skip_log =~ "Skipping plugin assignment #{stale_assignment_id}"
    assert first_skip_log =~ missing_device_uid
    assert first_skip_log =~ ":console_target_device_not_found"

    assert {:skipped, _} =
             :persistent_term.get(
               {AgentConfigGenerator, :plugin_assignment_skipped, stale_assignment_id},
               :none
             )

    repeat_skip_log =
      capture_log([level: :debug], fn ->
        {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
        assert config.plugins == []
      end)

    refute repeat_skip_log =~ "Skipping plugin assignment #{stale_assignment_id}"
    assert repeat_skip_log =~ "Still skipping plugin assignment #{stale_assignment_id}"

    Repo.query!("DELETE FROM platform.plugin_assignments WHERE id = $1", [
      Ecto.UUID.dump!(stale_assignment_id)
    ])

    {node, device_uid} = insert_pve_device!("192.0.2.20")
    assignment_id = insert_proxmox_console_assignment!(rule, secret, agent_uid, device_uid)

    uninventoried_skip_log =
      capture_log([level: :debug], fn ->
        {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
        assert config.plugins == []
      end)

    assert uninventoried_skip_log =~ "Skipping plugin assignment #{assignment_id}"
    assert uninventoried_skip_log =~ device_uid
    assert uninventoried_skip_log =~ ":unsupported_console_target"

    assert :persistent_term.get(
             {AgentConfigGenerator, :plugin_assignment_skipped, stale_assignment_id},
             :none
           ) == :none

    insert_legacy_pve_host_row!(system, node, device_uid)

    recovery_log =
      capture_log([level: :info], fn ->
        {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

        assert [%{plugin_id: "proxmox-console"} = plugin] = config.plugins
        assert [binding] = plugin.host_params["bindings"]
        assert binding["origin"] == "https://192.0.2.20:8006"
        assert binding["target_ids"]["device_uid"] == device_uid
        assert binding["target_ids"]["integration_id"] == rule.integration_id
        assert binding["target_ids"]["controller_id"] == rule.controller_id
      end)

    assert recovery_log =~ "Plugin assignment #{assignment_id} is delivered again"

    assert :persistent_term.get(
             {AgentConfigGenerator, :plugin_assignment_skipped, assignment_id},
             :none
           ) == :none

    Repo.query!("DELETE FROM platform.plugin_assignments WHERE id = $1", [
      Ecto.UUID.dump!(assignment_id)
    ])

    second_node = "pve-node-#{System.unique_integer([:positive])}"
    second_device_uid = "sr:device:#{second_node}"

    mixed_assignment_id =
      insert_proxmox_console_assignment!(rule, secret, agent_uid, [
        device_uid,
        second_device_uid
      ])

    first_drop_log =
      capture_log([level: :debug], fn ->
        {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

        assert [%{plugin_id: "proxmox-console"} = plugin] = config.plugins
        assert [%{"items" => [delivered_item]}] = plugin.params["inputs"]
        assert delivered_item["device_uid"] == device_uid
        assert [delivered_target] = plugin.params["targets"]
        assert delivered_target["device_uid"] == device_uid
        assert [binding] = plugin.host_params["bindings"]
        assert binding["target_ids"]["device_uid"] == device_uid
      end)

    assert first_drop_log =~
             "Dropping unresolvable Proxmox console target(s) from plugin assignment #{mixed_assignment_id}"

    assert first_drop_log =~ second_device_uid
    assert first_drop_log =~ ":console_target_device_not_found"

    assert {:dropped_targets, _} =
             :persistent_term.get(
               {AgentConfigGenerator, :plugin_assignment_skipped, mixed_assignment_id},
               :none
             )

    repeat_drop_log =
      capture_log([level: :debug], fn ->
        {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

        assert [%{plugin_id: "proxmox-console"} = plugin] = config.plugins
        assert [%{"items" => [%{"device_uid" => ^device_uid}]}] = plugin.params["inputs"]
        assert [%{"device_uid" => ^device_uid}] = plugin.params["targets"]
      end)

    refute repeat_drop_log =~
             "Dropping unresolvable Proxmox console target(s) from plugin assignment #{mixed_assignment_id}"

    assert repeat_drop_log =~
             "Still dropping unresolvable Proxmox console target(s) from plugin assignment #{mixed_assignment_id}"

    insert_pve_device!("192.0.2.21", second_node, second_device_uid)

    changed_reason_log =
      capture_log([level: :debug], fn ->
        {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
        assert [%{plugin_id: "proxmox-console"}] = config.plugins
      end)

    assert changed_reason_log =~
             "Dropping unresolvable Proxmox console target(s) from plugin assignment #{mixed_assignment_id}"

    assert changed_reason_log =~ second_device_uid
    assert changed_reason_log =~ ":unsupported_console_target"

    insert_legacy_pve_host_row!(system, second_node, second_device_uid)

    cleared_drop_log =
      capture_log([level: :info], fn ->
        {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

        assert [%{plugin_id: "proxmox-console"} = plugin] = config.plugins
        assert [%{"items" => items}] = plugin.params["inputs"]
        assert Enum.map(items, & &1["device_uid"]) == [device_uid, second_device_uid]

        assert Enum.map(plugin.params["targets"], & &1["device_uid"]) == [
                 device_uid,
                 second_device_uid
               ]
      end)

    assert cleared_drop_log =~
             "Proxmox console target drops cleared for plugin assignment #{mixed_assignment_id}"

    assert :persistent_term.get(
             {AgentConfigGenerator, :plugin_assignment_skipped, mixed_assignment_id},
             :none
           ) == :none
  end

  test "fresh policy broker grant is reused and still resolves with an audit row",
       %{admin: admin, system: system, agent_uid: agent_uid, unique_id: unique_id} do
    {:ok, _agent} = create_connected_agent(admin, agent_uid)
    package = create_approved_plugin_package!(admin, unique_id)
    secret = create_proxmox_secret!(admin, unique_id)

    {:ok, grant} =
      %{
        secret_id: secret.id,
        grant_type: "proxmox_api_token",
        consumer_kind: :plugin,
        consumer_id: "proxmox-inventory-#{unique_id}",
        purpose: "inventory_enrichment",
        agent_id: agent_uid,
        resolution_location: :agent,
        ttl_seconds: 3_600
      }
      |> CredentialBrokerGrant.issue_attrs()
      |> CredentialBrokerGrant.issue_grant(actor: system)

    _assignment =
      PluginAssignment
      |> Ash.Changeset.for_create(
        :create,
        %{
          agent_uid: agent_uid,
          plugin_package_id: package.id,
          source: :policy,
          source_key: "policy-key-fresh-#{unique_id}",
          policy_id: "network-credential-rule:rule-fresh-#{unique_id}",
          enabled: true,
          params: %{
            "credential_broker" => CredentialBrokerGrant.to_payload(grant),
            "api_token_secret_ref" => SecretRefs.network_credential_ref(to_string(secret.id))
          }
        },
        actor: system
      )
      |> create_without_notifications!()

    {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

    assert [plugin] = config.plugins
    assert plugin.params["api_token"] == @api_token_payload
    # fresh grant is reused as-is
    assert plugin.params["credential_broker"]["grant_id"] == to_string(grant.id)

    assert {:ok, [audit | _]} =
             CredentialSecretResolutionAudit.list_for_secret(secret.id, actor: system)

    assert audit.outcome == :success
    assert audit.grant_id == to_string(grant.id)
  end

  test "each credential rule's assignment of one plugin is delivered with its own credential",
       %{admin: admin, system: system, agent_uid: agent_uid, unique_id: unique_id} do
    {:ok, _agent} = create_connected_agent(admin, agent_uid)
    package = create_approved_plugin_package!(admin, unique_id)
    secret_a = create_proxmox_secret!(admin, "#{unique_id}-a")
    secret_b = create_proxmox_secret!(admin, "#{unique_id}-b", @rotated_api_token_payload)

    assignment_for = fn owner, secret ->
      {:ok, grant} =
        %{
          secret_id: secret.id,
          grant_type: "proxmox_api_token",
          consumer_kind: :plugin,
          consumer_id: package.plugin_id,
          purpose: "inventory_enrichment",
          agent_id: agent_uid,
          resolution_location: :agent,
          ttl_seconds: 3_600
        }
        |> CredentialBrokerGrant.issue_attrs()
        |> CredentialBrokerGrant.issue_grant(actor: system)

      PluginAssignment
      |> Ash.Changeset.for_create(
        :create,
        %{
          agent_uid: agent_uid,
          plugin_package_id: package.id,
          source: :policy,
          source_key: "policy-key-#{owner}-#{unique_id}",
          policy_id: "network-credential-rule:rule-#{owner}-#{unique_id}:inventory",
          enabled: true,
          params: %{
            "credential_broker" => CredentialBrokerGrant.to_payload(grant),
            "api_token_secret_ref" => SecretRefs.network_credential_ref(to_string(secret.id))
          }
        },
        actor: system
      )
      |> create_without_notifications!()
    end

    assignment_a = assignment_for.("a", secret_a)
    assignment_b = assignment_for.("b", secret_b)

    {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)

    delivered = Map.new(config.plugins, &{&1.assignment_id, &1.params["api_token"]})

    assert delivered == %{
             to_string(assignment_a.id) => @api_token_payload,
             to_string(assignment_b.id) => @rotated_api_token_payload
           }
  end

  test "controller-list policy grants resolve independently and keep config version stable",
       %{admin: admin, system: system, agent_uid: agent_uid, unique_id: unique_id} do
    {:ok, _agent} = create_connected_agent(admin, agent_uid)
    package = create_approved_awx_inventory_package!(admin, unique_id)
    secret = create_proxmox_secret!(admin, unique_id)
    stale_grant_1 = issue_expired_grant!(system, secret, agent_uid)
    stale_grant_2 = issue_expired_grant!(system, secret, agent_uid)

    _assignment =
      PluginAssignment
      |> Ash.Changeset.for_create(
        :create,
        %{
          agent_uid: agent_uid,
          plugin_package_id: package.id,
          source: :policy,
          source_key: "awx-policy-key-#{unique_id}",
          policy_id: "ansible:awx-inventory-sync",
          enabled: true,
          interval_seconds: 300,
          timeout_seconds: 60,
          params: %{
            "controllers" => [
              %{
                "controller_id" => "awx-a-#{unique_id}",
                "base_url" => "https://awx-a.example.invalid",
                "credential_broker" => CredentialBrokerGrant.to_payload(stale_grant_1),
                "api_token_secret_ref" => SecretRefs.network_credential_ref(to_string(secret.id))
              },
              %{
                "controller_id" => "awx-b-#{unique_id}",
                "base_url" => "https://awx-b.example.invalid",
                "credential_broker" => CredentialBrokerGrant.to_payload(stale_grant_2),
                "api_token_secret_ref" => SecretRefs.network_credential_ref(to_string(secret.id))
              }
            ]
          }
        },
        actor: system
      )
      |> create_without_notifications!()

    {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
    assert [plugin] = config.plugins
    controllers = plugin.params["controllers"]

    assert Enum.map(controllers, & &1["api_token"]) == [
             @awx_host_credential_sentinel,
             @awx_host_credential_sentinel
           ]

    refute inspect(plugin.params) =~ @api_token_payload

    refute Enum.any?(controllers, fn controller ->
             Enum.any?(
               ["_secret_material", "api_token_secret_ref", "credential_broker"],
               &Map.has_key?(controller, &1)
             )
           end)

    assert Enum.all?(controllers, fn controller ->
             is_binary(controller["controller_id"]) and controller["controller_id"] != "" and
               is_binary(controller["base_url"]) and controller["base_url"] != "" and
               controller["api_token"] == @awx_host_credential_sentinel
           end)

    assert plugin.host_params["schema"] == "serviceradar.awx_inventory_host_credentials.v1"

    assert Enum.map(plugin.host_params["controllers"], & &1["api_token"]) == [
             @api_token_payload,
             @api_token_payload
           ]

    assert {:ok, resolution_audits} =
             CredentialSecretResolutionAudit.list_for_secret(secret.id, actor: system)

    reminted_grant_ids =
      resolution_audits
      |> Enum.map(& &1.grant_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    # Both controllers carry an identical grant scope, so delivery reuses the
    # one live grant it issues for the first instead of minting per payload.
    assert length(reminted_grant_ids) == 1
    refute to_string(stale_grant_1.id) in reminted_grant_ids
    refute to_string(stale_grant_2.id) in reminted_grant_ids

    proto = AgentConfigGenerator.to_proto_response(config)
    [proto_assignment] = proto.plugin_config.assignments
    transported_params = Jason.decode!(proto_assignment.params_json)
    transported_host_params = Jason.decode!(proto_assignment.host_params_json)

    assert get_in(transported_params, ["controllers", Access.at(0), "api_token"]) ==
             @awx_host_credential_sentinel

    # Mixed-version contract: an old agent decodes params_json and ignores the
    # unknown host_params_json protobuf field. It sees only this public sentinel
    # config, so scheduled sync fails closed instead of disclosing a bearer to
    # Wasm get_config.
    refute Map.has_key?(transported_params, "_serviceradar_host_credentials")
    refute proto_assignment.params_json =~ @api_token_payload

    assert get_in(transported_host_params, [
             "controllers",
             Access.at(0),
             "api_token"
           ]) == @api_token_payload

    {:ok, config2} = AgentConfigGenerator.generate_config(agent_uid, @default_partition)
    assert config.config_version == config2.config_version
  end

  test "unchanged-config poll (:not_modified) writes no credential-resolution audit (#4428)",
       %{admin: admin, system: system, agent_uid: agent_uid, unique_id: unique_id} do
    {:ok, _agent} = create_connected_agent(admin, agent_uid)
    package = create_approved_plugin_package!(admin, unique_id)
    secret = create_proxmox_secret!(admin, unique_id)

    # Fresh (long-TTL) grant so it is reused across polls — isolates the audit
    # behavior from grant re-mint.
    {:ok, grant} =
      %{
        secret_id: secret.id,
        grant_type: "proxmox_api_token",
        consumer_kind: :plugin,
        consumer_id: "proxmox-inventory-#{unique_id}",
        purpose: "inventory_enrichment",
        agent_id: agent_uid,
        resolution_location: :agent,
        ttl_seconds: 3_600
      }
      |> CredentialBrokerGrant.issue_attrs()
      |> CredentialBrokerGrant.issue_grant(actor: system)

    _assignment =
      PluginAssignment
      |> Ash.Changeset.for_create(
        :create,
        %{
          agent_uid: agent_uid,
          plugin_package_id: package.id,
          source: :policy,
          source_key: "policy-key-notmod-#{unique_id}",
          policy_id: "network-credential-rule:rule-notmod-#{unique_id}",
          enabled: true,
          params: %{
            "credential_broker" => CredentialBrokerGrant.to_payload(grant),
            "api_token_secret_ref" => SecretRefs.network_credential_ref(to_string(secret.id))
          }
        },
        actor: system
      )
      |> create_without_notifications!()

    # First fetch (agent has no version) delivers and audits.
    assert {:ok, config} =
             AgentConfigGenerator.get_config_if_changed(agent_uid, @default_partition, "")

    assert config.plugins |> hd() |> Map.fetch!(:params) |> Map.get("api_token") ==
             @api_token_payload

    after_delivery = audit_count(secret, system)
    assert after_delivery >= 1

    # Steady-state poll with the current version: :not_modified, and crucially NO
    # new audit row even though the credential is still resolved to compute the
    # version hash (fj #4428).
    assert :not_modified =
             AgentConfigGenerator.get_config_if_changed(
               agent_uid,
               @default_partition,
               config.config_version
             )

    assert audit_count(secret, system) == after_delivery

    # A poll whose version no longer matches DOES deliver and audit again.
    assert {:ok, _config2} =
             AgentConfigGenerator.get_config_if_changed(
               agent_uid,
               @default_partition,
               "stale-version"
             )

    assert audit_count(secret, system) == after_delivery + 1
  end

  # The same policy assignment as the re-mint test above: its stored broker
  # grant is expired, so every generation mints a fresh one.
  defp create_expired_grant_policy_assignment!(admin, system, agent_uid, unique_id) do
    package = create_approved_plugin_package!(admin, unique_id, @proxmox_config_schema)
    secret = create_proxmox_secret!(admin, unique_id)

    stale_payload =
      system |> issue_expired_grant!(secret, agent_uid) |> CredentialBrokerGrant.to_payload()

    PluginAssignment
    |> Ash.Changeset.for_create(
      :create,
      %{
        agent_uid: agent_uid,
        plugin_package_id: package.id,
        source: :policy,
        source_key: "policy-key-#{unique_id}",
        policy_id: "network-credential-rule:rule-#{unique_id}",
        enabled: true,
        interval_seconds: 300,
        timeout_seconds: 30,
        params: %{
          "schema" => "serviceradar.plugin_inputs.v1",
          "policy_id" => "network-credential-rule:rule-#{unique_id}",
          "policy_version" => 1,
          "agent_id" => agent_uid,
          "generated_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "inputs" => [
            %{
              "name" => "targets",
              "entity" => "devices",
              "query" => "in:devices vendor:proxmox",
              "chunk_index" => 0,
              "chunk_total" => 1,
              "chunk_hash" => String.duplicate("b", 64),
              "items" => [%{"ip" => "192.0.2.14", "hostname" => "pve-test-01"}]
            }
          ],
          "template" => %{
            "credential_broker" => stale_payload,
            "api_token_secret_ref" => SecretRefs.network_credential_ref(to_string(secret.id)),
            "timeout_ms" => 30_000
          }
        }
      },
      actor: system
    )
    |> create_without_notifications!()
  end

  # An enabled default SNMP profile that applies to every agent, so the SNMP
  # section this agent receives names a profile rather than the disabled config.
  defp default_snmp_profile!(actor) do
    case SNMPProfile |> Ash.Query.for_read(:get_default, %{}) |> Ash.read_one(actor: actor) do
      {:ok, %SNMPProfile{agent_ids: []} = profile} ->
        profile

      {:ok, nil} ->
        {:ok, profile} =
          SNMPProfile
          |> Ash.Changeset.for_create(
            :create,
            %{name: "Default SNMP #{System.unique_integer([:positive])}", enabled: true},
            actor: actor
          )
          |> Ash.create(actor: actor)

        {:ok, profile} =
          profile
          |> Ash.Changeset.for_update(:set_as_default, %{}, actor: actor)
          |> Ash.update(actor: actor)

        profile
    end
  end

  # Runs the SNMP section lookup AgentConfigGenerator makes for this agent (same
  # ConfigServer key: partition, agent, no device) from a process whose profile
  # read fails. The process checks out its own connection with a short
  # lock_timeout while this test holds an exclusive lock on the SNMP profile
  # table, so the read errors out; rolling back the savepoint releases the lock.
  defp compile_snmp_section_with_failing_reads(agent_uid) do
    {:error, {:snmp_section, result}} =
      Repo.transaction(fn ->
        Repo.query!("LOCK TABLE platform.snmp_profiles IN ACCESS EXCLUSIVE MODE")
        Repo.rollback({:snmp_section, compile_snmp_section_on_own_connection(agent_uid)})
      end)

    result
  end

  defp compile_snmp_section_on_own_connection(agent_uid) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        :ok = Sandbox.checkout(Repo)
        Repo.query!("SET LOCAL lock_timeout = '100ms'")

        result =
          ConfigServer.get_config(:snmp, @default_partition, agent_uid,
            actor: SystemActor.system(:snmp_config_loader),
            device_uid: nil,
            agent_id: agent_uid
          )

        send(parent, {:snmp_section, self(), result})
      end)

    receive do
      {:snmp_section, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        flunk("SNMP section compile exited: #{inspect(reason)}")
    after
      30_000 -> flunk("SNMP section compile did not finish")
    end
  end

  defp cross_second_boundary do
    Process.sleep(1_001 - rem(System.os_time(:millisecond), 1_000))
  end

  defp audit_count(secret, system) do
    {:ok, audits} = CredentialSecretResolutionAudit.list_for_secret(secret.id, actor: system)
    length(audits)
  end

  defp create_without_notifications!(changeset) do
    case Ash.create(changeset,
           domain: ServiceRadar.Plugins,
           return_notifications?: true
         ) do
      {:ok, record, _notifications} -> record
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  defp update_without_notifications!(changeset) do
    case Ash.update(changeset,
           domain: ServiceRadar.Plugins,
           return_notifications?: true
         ) do
      {:ok, record, _notifications} -> record
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  defp create_connected_agent(actor, agent_uid, capabilities \\ []) do
    Agent
    |> Ash.Changeset.for_create(
      :register_connected,
      %{
        uid: agent_uid,
        name: "Credential Delivery Agent #{agent_uid}",
        host: "127.0.0.1",
        port: 50_051,
        capabilities: capabilities,
        metadata: %{}
      },
      actor: actor
    )
    |> Ash.create()
  end

  defp create_proxmox_inventory_rule!(system, secret, agent_uid) do
    {:ok, rule} =
      NetworkCredentialRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "pve-inventory-rule-#{System.unique_integer([:positive])}",
          provider: "proxmox",
          auth_method: :proxmox_api_token,
          purpose: :inventory_enrichment,
          target_query: "in:devices",
          scope_type: :agent,
          scope_value: agent_uid,
          secret_id: secret.id,
          tls_policy: :verify
        }
      )
      |> Ash.create(actor: system)

    rule
  end

  # The real host-authority plugin id, as a materialized assignment carries it:
  # the stored template holds the grant's scope and no grant.
  defp insert_proxmox_inventory_assignment!(rule, secret, agent_uid) do
    now = DateTime.utc_now()
    package_id = Ecto.UUID.generate()
    assignment_id = Ecto.UUID.generate()
    # The unsuffixed form PluginAssignmentMaterializer.policy_id_for_rule/2
    # writes for inventory_enrichment: the only form
    # ProxmoxSourceScopeResolver accepts for a proxmox-inventory assignment.
    policy_id = "network-credential-rule:#{rule.id}"
    secret_ref = SecretRefs.network_credential_ref(to_string(secret.id))

    scope =
      CredentialBrokerGrant.scope_payload(%{
        secret_id: secret.id,
        secret_ref: secret_ref,
        credential_rule_id: rule.id,
        grant_type: "proxmox_api_token",
        consumer_kind: :plugin,
        consumer_id: "proxmox-inventory",
        purpose: "inventory_enrichment",
        agent_id: agent_uid,
        resolution_location: :agent,
        inject: %{"type" => "http_header", "name" => "Authorization", "scheme" => "PVEAPIToken"},
        allowed_methods: ["GET"],
        allowed_paths: ["/api2/json/version", "/api2/json/nodes"],
        ttl_seconds: 300
      })

    Repo.insert_all("plugins", [
      %{
        plugin_id: "proxmox-inventory",
        name: "proxmox-inventory",
        inserted_at: now,
        updated_at: now
      }
    ])

    Repo.insert_all("plugin_packages", [
      %{
        id: Ecto.UUID.dump!(package_id),
        plugin_id: "proxmox-inventory",
        name: "proxmox-inventory",
        version: "0.1.10",
        entrypoint: "run_check",
        wasm_object_key: "plugins/proxmox-inventory/#{assignment_id}/plugin.wasm",
        status: "approved",
        outputs: "serviceradar.plugin_result.v1",
        manifest: %{},
        config_schema: %{},
        inserted_at: now,
        updated_at: now
      }
    ])

    Repo.insert_all("plugin_assignments", [
      %{
        id: Ecto.UUID.dump!(assignment_id),
        agent_uid: agent_uid,
        partition_id: @default_partition,
        plugin_id: "proxmox-inventory",
        plugin_package_id: Ecto.UUID.dump!(package_id),
        source: "policy",
        policy_id: policy_id,
        enabled: true,
        interval_seconds: 300,
        timeout_seconds: 30,
        params: %{
          "schema" => "serviceradar.plugin_inputs.v1",
          "policy_id" => policy_id,
          "policy_version" => 1,
          "credential_rule_id" => to_string(rule.id),
          "agent_id" => agent_uid,
          "generated_at" => DateTime.to_iso8601(now),
          "inputs" => [
            %{
              "name" => "targets",
              "entity" => "devices",
              "query" => "in:devices",
              "chunk_index" => 0,
              "chunk_total" => 1,
              "chunk_hash" => String.duplicate("a", 64),
              "items" => [
                %{
                  "uid" => "sr:device:pve-a",
                  "ip" => "192.0.2.10",
                  "hostname" => "pve-a",
                  "target_kind" => "pve_host"
                }
              ]
            }
          ],
          "template" => %{"credential_broker" => scope, "api_token_secret_ref" => secret_ref}
        },
        inserted_at: now,
        updated_at: now
      }
    ])

    assignment_id
  end

  defp create_proxmox_console_rule!(system, secret, agent_uid) do
    {:ok, rule} =
      NetworkCredentialRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "pve-console-rule-#{System.unique_integer([:positive])}",
          provider: "proxmox",
          auth_method: :proxmox_api_token,
          purpose: :console_access,
          target_query: "in:devices",
          scope_type: :agent,
          scope_value: agent_uid,
          secret_id: secret.id,
          tls_policy: :verify
        }
      )
      |> Ash.create(actor: system)

    rule
  end

  # A PVE host whose virtualization row carries native identity but no v3
  # source scope, as rows written before the v3 insert guard do. The guard is
  # disabled only for this insert.
  defp insert_pve_device!(ip) do
    node = "pve-node-#{System.unique_integer([:positive])}"
    device_uid = "sr:device:#{node}"
    insert_pve_device!(ip, node, device_uid)
  end

  defp insert_pve_device!(ip, node, device_uid) do
    now = DateTime.utc_now()

    Repo.insert_all("ocsf_devices", [
      %{
        uid: device_uid,
        type_id: 0,
        hostname: node,
        ip: ip,
        vendor_name: "Proxmox",
        is_available: true,
        metadata: %{},
        first_seen_time: now,
        last_seen_time: now
      }
    ])

    {node, device_uid}
  end

  defp insert_legacy_pve_host_row!(system, node, device_uid) do
    Repo.query!(
      "ALTER TABLE platform.virtualization_hosts DISABLE TRIGGER virtualization_hosts_identity_immutable_guard"
    )

    try do
      VirtualizationHost
      |> Ash.Changeset.for_create(:create, %{
        provider: "proxmox",
        provider_ref: "proxmox:node:#{node}",
        device_uid: device_uid,
        name: node,
        identity_state: :legacy,
        native_cluster_id: "cluster-a",
        object_kind: "node",
        native_object_id: node,
        metadata: %{}
      })
      |> Ash.create!(actor: system)
    after
      Repo.query!(
        "ALTER TABLE platform.virtualization_hosts ENABLE TRIGGER virtualization_hosts_identity_immutable_guard"
      )
    end
  end

  # The console form PluginAssignmentMaterializer writes: a ":console_access"
  # policy id and a template holding the grant's scope and no grant.
  defp insert_proxmox_console_assignment!(rule, secret, agent_uid, device_uids) do
    now = DateTime.utc_now()
    package_id = Ecto.UUID.generate()
    assignment_id = Ecto.UUID.generate()
    policy_id = "network-credential-rule:#{rule.id}:console_access"
    secret_ref = SecretRefs.network_credential_ref(to_string(secret.id))

    items =
      device_uids
      |> List.wrap()
      |> Enum.map(&%{"device_uid" => &1, "target_kind" => "pve_host"})

    scope =
      CredentialBrokerGrant.scope_payload(%{
        secret_id: secret.id,
        secret_ref: secret_ref,
        credential_rule_id: rule.id,
        grant_type: "proxmox_api_token",
        consumer_kind: :plugin,
        consumer_id: "proxmox-console",
        purpose: "console_access",
        agent_id: agent_uid,
        resolution_location: :agent,
        inject: %{"type" => "http_header", "name" => "Authorization", "scheme" => "PVEAPIToken"},
        allowed_methods: ["GET", "POST"],
        allowed_paths: [],
        ttl_seconds: 300
      })

    Repo.insert_all(
      "plugins",
      [
        %{
          plugin_id: "proxmox-console",
          name: "proxmox-console",
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing
    )

    Repo.insert_all("plugin_packages", [
      %{
        id: Ecto.UUID.dump!(package_id),
        plugin_id: "proxmox-console",
        name: "proxmox-console",
        version: "0.1.#{System.unique_integer([:positive])}",
        entrypoint: "run_console",
        wasm_object_key: "plugins/proxmox-console/#{assignment_id}/plugin.wasm",
        status: "approved",
        outputs: "console",
        manifest: %{},
        config_schema: %{},
        inserted_at: now,
        updated_at: now
      }
    ])

    Repo.insert_all("plugin_assignments", [
      %{
        id: Ecto.UUID.dump!(assignment_id),
        agent_uid: agent_uid,
        partition_id: @default_partition,
        plugin_id: "proxmox-console",
        plugin_package_id: Ecto.UUID.dump!(package_id),
        source: "policy",
        policy_id: policy_id,
        enabled: true,
        interval_seconds: 300,
        timeout_seconds: 30,
        params: %{
          "schema" => "serviceradar.plugin_inputs.v1",
          "policy_id" => policy_id,
          "policy_version" => 1,
          "credential_rule_id" => to_string(rule.id),
          "agent_id" => agent_uid,
          "generated_at" => DateTime.to_iso8601(now),
          "targets" => items,
          "inputs" => [
            %{
              "name" => "targets",
              "entity" => "devices",
              "query" => "in:devices",
              "chunk_index" => 0,
              "chunk_total" => 1,
              "chunk_hash" => String.duplicate("b", 64),
              "items" => items
            }
          ],
          "template" => %{"credential_broker" => scope, "api_token_secret_ref" => secret_ref}
        },
        inserted_at: now,
        updated_at: now
      }
    ])

    assignment_id
  end

  defp grant_count(secret) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.credential_broker_grants WHERE secret_id = $1",
        [Ecto.UUID.dump!(to_string(secret.id))]
      )

    count
  end

  defp binding_denials(binding_id) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM platform.credential_secret_resolution_audits
        WHERE outcome = 'denied' AND metadata->>'binding_id' = $1
        """,
        [binding_id]
      )

    count
  end

  defp register_control_session!(agent_uid, partition_id) do
    assert {:ok, _pid} =
             ProcessRegistry.register(
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

  defp await_control_partition!(_agent_uid, _partition_id, 0),
    do: flunk("test control-session partition did not converge")

  defp await_control_partition!(agent_uid, partition_id, attempts) do
    case AgentCommandBus.resolve_control_session_evidence(partition_id, agent_uid, nil) do
      {:ok, %{agent_id: ^agent_uid, partition_id: ^partition_id}} ->
        :ok

      _other ->
        Process.sleep(10)
        await_control_partition!(agent_uid, partition_id, attempts - 1)
    end
  end

  defp create_proxmox_secret!(actor, unique_id, payload \\ @api_token_payload) do
    {:ok, secret} =
      NetworkCredentialSecret.create_secret(
        %{
          name: "proxmox-inventory-secret-#{unique_id}",
          provider: "proxmox",
          credential_kind: :api_token,
          secret_payload: payload
        },
        actor: actor
      )

    secret
  end

  defp issue_expired_grant!(system, secret, agent_uid) do
    {:ok, grant} =
      %{
        secret_id: secret.id,
        grant_type: "proxmox_api_token",
        consumer_kind: :plugin,
        consumer_id: "proxmox-inventory",
        purpose: "inventory_enrichment",
        agent_id: agent_uid,
        resolution_location: :agent,
        ttl_seconds: 300,
        expires_at: DateTime.shift(DateTime.utc_now(), hour: -1)
      }
      |> CredentialBrokerGrant.issue_attrs()
      |> CredentialBrokerGrant.issue_grant(actor: system)

    grant
  end

  defp create_approved_plugin_package!(actor, unique_id, config_schema \\ %{}) do
    plugin_id = "proxmox-inventory-#{unique_id}"

    _plugin =
      Plugin
      |> Ash.Changeset.for_create(
        :create,
        %{plugin_id: plugin_id, name: "Proxmox Inventory #{unique_id}"},
        actor: actor
      )
      |> create_without_notifications!()

    package =
      PluginPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          plugin_id: plugin_id,
          name: "Proxmox Inventory #{unique_id}",
          version: "1.0.0",
          entrypoint: "run_check",
          outputs: "serviceradar.plugin_result.v1",
          manifest: %{
            "id" => plugin_id,
            "name" => "Proxmox Inventory #{unique_id}",
            "version" => "1.0.0",
            "entrypoint" => "run_check",
            "capabilities" => ["http_request", "submit_result"],
            "outputs" => "serviceradar.plugin_result.v1",
            "resources" => %{
              "requested_memory_mb" => 64,
              "requested_cpu_ms" => 1000
            }
          },
          config_schema: config_schema,
          display_contract: %{},
          content_hash: "sha256:#{unique_id}",
          signature: %{},
          source_type: :upload
        },
        actor: actor
      )
      |> create_without_notifications!()

    package =
      package
      |> Ash.Changeset.for_update(
        :update,
        %{wasm_object_key: "plugins/#{unique_id}/plugin.wasm"},
        actor: actor
      )
      |> update_without_notifications!()

    package =
      package
      |> Ash.Changeset.for_update(:approve, %{approved_by: "test"}, actor: actor)
      |> update_without_notifications!()

    package
  end

  defp create_approved_awx_inventory_package!(actor, unique_id) do
    plugin_id = "awx-inventory-sync"

    _plugin =
      Plugin
      |> Ash.Changeset.for_create(
        :create,
        %{plugin_id: plugin_id, name: "AWX Inventory Sync #{unique_id}"},
        actor: actor
      )
      |> create_without_notifications!()

    package =
      PluginPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          plugin_id: plugin_id,
          name: "AWX Inventory Sync #{unique_id}",
          version: "0.1.6",
          entrypoint: "inventory_sync",
          outputs: "serviceradar.plugin_result.v1",
          manifest: %{
            "id" => plugin_id,
            "name" => "AWX Inventory Sync #{unique_id}",
            "version" => "0.1.6",
            "entrypoint" => "inventory_sync",
            "capabilities" => ["get_config", "http_request", "submit_result"],
            "outputs" => "serviceradar.plugin_result.v1",
            "resources" => %{
              "requested_memory_mb" => 64,
              "requested_cpu_ms" => 1000
            }
          },
          config_schema: %{},
          display_contract: %{},
          content_hash: "sha256:awx-inventory-#{unique_id}",
          signature: %{},
          source_type: :upload
        },
        actor: actor
      )
      |> create_without_notifications!()

    package =
      package
      |> Ash.Changeset.for_update(
        :update,
        %{wasm_object_key: "plugins/awx-inventory/#{unique_id}/plugin.wasm"},
        actor: actor
      )
      |> update_without_notifications!()

    package =
      package
      |> Ash.Changeset.for_update(:approve, %{approved_by: "test"}, actor: actor)
      |> update_without_notifications!()

    package
  end
end
