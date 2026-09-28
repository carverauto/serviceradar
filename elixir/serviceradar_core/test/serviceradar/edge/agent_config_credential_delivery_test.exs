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

  alias Ecto.Adapters.SQL.Sandbox
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compiler
  alias ServiceRadar.AgentConfig.ConfigCache
  alias ServiceRadar.AgentConfig.ConfigServer
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.CredentialSecretResolutionAudit
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Infrastructure.Agent
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
        actor: admin
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

  test "consecutive generations that each re-mint the broker grant keep one config version",
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

    assert delivered_grant_ids |> Enum.uniq() |> length() == 4
    assert configs |> Enum.map(& &1.config_version) |> Enum.uniq() |> length() == 1
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
        actor: admin
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
        actor: admin
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

    assert length(reminted_grant_ids) == 2
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
        actor: admin
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
      actor: admin
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

  defp create_connected_agent(actor, agent_uid) do
    Agent
    |> Ash.Changeset.for_create(
      :register_connected,
      %{
        uid: agent_uid,
        name: "Credential Delivery Agent #{agent_uid}",
        host: "127.0.0.1",
        port: 50_051,
        metadata: %{}
      },
      actor: actor
    )
    |> Ash.create()
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

  defp create_proxmox_secret!(actor, unique_id) do
    {:ok, secret} =
      NetworkCredentialSecret.create_secret(
        %{
          name: "proxmox-inventory-secret-#{unique_id}",
          provider: "proxmox",
          credential_kind: :api_token,
          secret_payload: @api_token_payload
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
        expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
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
