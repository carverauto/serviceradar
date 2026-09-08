defmodule ServiceRadar.Edge.ProxmoxConsoleSessionsTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialUsePolicy
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Edge.ProxmoxConsoleSession
  alias ServiceRadar.Edge.ProxmoxConsoleSessions
  alias ServiceRadar.Inventory.IntegrationIdentity
  alias ServiceRadar.Inventory.VirtualizationGuest
  alias ServiceRadar.Inventory.VirtualizationHost
  alias ServiceRadar.Repo

  defmodule Previewer do
    @moduledoc false

    def preview_rule(_rule, _opts) do
      {:ok, %{sample_devices: [%{uid: Process.get(:proxmox_console_test_device_uid)}]}}
    end
  end

  defmodule AssignmentResolver do
    @moduledoc false

    def resolve(rule, agent_id, _opts) do
      assignment_id = "018f3f56-aaaa-7666-8777-123456789abc"
      package_id = "018f3f56-bbbb-7666-8777-123456789abc"
      policy_id = "network-credential-rule:#{rule.id}:console_access"

      {:ok,
       %{
         id: assignment_id,
         updated_at: ~U[2026-07-13 12:00:00Z],
         source: :policy,
         source_key: "#{policy_id}:#{agent_id}",
         policy_id: policy_id,
         agent_uid: agent_id,
         partition_id: "farm01",
         plugin_id: "proxmox-console",
         plugin_package_id: package_id,
         plugin_package: %{
           id: package_id,
           plugin_id: "proxmox-console",
           entrypoint: "run_console",
           status: :approved,
           version: "1.0.0"
         },
         params: %{
           "policy_id" => policy_id,
           "policy_version" => 1,
           "credential_rule_id" => to_string(rule.id),
           "api_token" => "__SERVICERADAR_HOST_CREDENTIAL__"
         },
         enabled: true
       }}
    end
  end

  defmodule EdgePrincipalResolver do
    @moduledoc false

    def resolve(partition_id, agent_id),
      do: {:ok, %{agent_id: agent_id, partition_id: partition_id}}
  end

  @system_actor SystemActor.system(:proxmox_console_sessions_test)
  @console_actor %{
    id: "018f3f56-1111-7666-8777-123456789abc",
    email: "console-operator@example.test",
    role: :admin,
    permissions:
      MapSet.new([
        "devices.view",
        "devices.console.open",
        "devices.console.credentials.use"
      ])
  }

  setup do
    previous_resolver =
      Application.get_env(:serviceradar_core, :proxmox_console_edge_principal_resolver)

    Application.put_env(
      :serviceradar_core,
      :proxmox_console_edge_principal_resolver,
      EdgePrincipalResolver
    )

    on_exit(fn ->
      if previous_resolver do
        Application.put_env(
          :serviceradar_core,
          :proxmox_console_edge_principal_resolver,
          previous_resolver
        )
      else
        Application.delete_env(:serviceradar_core, :proxmox_console_edge_principal_resolver)
      end
    end)

    insert_console_actor!()
    :ok
  end

  test "browser tickets are single-use and arbitrary request metadata is never persisted" do
    uid = unique_uid("ticket")
    secret = create_secret!("ticket")
    rule = create_rule!(secret, scope_value: "agent-ticket")
    insert_device!(uid, agent_id: "agent-ticket", gateway_id: "gateway-ticket", source_rule: rule)
    Process.put(:proxmox_console_test_device_uid, uid)

    assert {:ok, %{session: session, ticket: ticket}} =
             ProxmoxConsoleSessions.request_open(
               uid,
               %{
                 metadata: %{
                   "private_key" => private_key_fixture(),
                   "safe" => "kept",
                   "remote_console" => %{"provider" => "caller-controlled"}
                 }
               },
               previewer: Previewer,
               assignment_resolver: AssignmentResolver,
               actor: @console_actor
             )

    refute inspect(session) =~ ticket
    refute Map.has_key?(session.metadata, "private_key")
    refute Map.has_key?(session.metadata, "safe")
    assert session.metadata["plugin_assignment_id"] == "018f3f56-aaaa-7666-8777-123456789abc"
    assert session.metadata["plugin_assignment_version"] == 1
    assert session.metadata["plugin_assignment_policy_fingerprint"] =~ ~r/\A[0-9a-f]{64}\z/

    assert session.metadata["credential_rule"]["assignment_policy_fingerprint"] ==
             session.metadata["plugin_assignment_policy_fingerprint"]

    refute Map.has_key?(session.metadata["credential_rule"], "secret_id")
    assert session.metadata["remote_console"]["schema"] == "serviceradar.remote_console_target.v1"
    assert session.metadata["remote_console"]["provider"] == "proxmox"
    assert session.metadata["remote_console"]["target_type"] == "host"
    assert session.metadata["remote_console"]["protocol"] == "proxmox-termproxy"
    assert session.metadata["remote_console"]["transport"] == "pty"
    assert session.metadata["remote_console"]["agent_id"] == "agent-ticket"
    refute inspect(session.metadata) =~ "PRIVATE KEY"

    assert {:ok, %ProxmoxConsoleSession{status: :attached}} =
             ProxmoxConsoleSessions.attach_with_ticket(ticket,
               session_id: session.id,
               assignment_resolver: AssignmentResolver,
               previewer: Previewer,
               actor: @console_actor
             )

    assert {:error, :invalid_or_expired_ticket} =
             ProxmoxConsoleSessions.attach_with_ticket(ticket,
               session_id: session.id,
               assignment_resolver: AssignmentResolver,
               previewer: Previewer,
               actor: @console_actor
             )
  end

  test "attach revalidates the current actor policy before broker startup" do
    uid = unique_uid("attach-policy")
    secret = create_secret!("attach-policy")
    rule = create_rule!(secret, scope_value: "agent-attach-policy")

    insert_device!(uid,
      agent_id: "agent-attach-policy",
      gateway_id: "gateway-attach-policy",
      source_rule: rule
    )

    Process.put(:proxmox_console_test_device_uid, uid)

    assert {:ok, %{session: session, ticket: ticket}} =
             ProxmoxConsoleSessions.request_open(
               uid,
               %{},
               previewer: Previewer,
               assignment_resolver: AssignmentResolver,
               actor: @console_actor
             )

    rule
    |> Ash.Changeset.for_update(:update, %{
      metadata: %{
        "credential_use_policy" => %{
          "schema" => CredentialUsePolicy.schema(),
          "roles" => ["viewer"]
        }
      }
    })
    |> Ash.update!(actor: @system_actor)

    assert {:error, :credential_use_policy_denied} =
             ProxmoxConsoleSessions.attach_with_ticket(ticket,
               session_id: session.id,
               assignment_resolver: AssignmentResolver,
               previewer: Previewer,
               actor: @console_actor
             )
  end

  test "attach fails closed when the exact console package is no longer approved" do
    uid = unique_uid("attach-package")
    secret = create_secret!("attach-package")
    rule = create_rule!(secret, scope_value: "agent-attach-package")

    insert_device!(uid,
      agent_id: "agent-attach-package",
      gateway_id: "gateway-attach-package",
      source_rule: rule
    )

    Process.put(:proxmox_console_test_device_uid, uid)

    assert {:ok, %{session: session, ticket: ticket}} =
             ProxmoxConsoleSessions.request_open(
               uid,
               %{},
               previewer: Previewer,
               assignment_resolver: AssignmentResolver,
               actor: @console_actor
             )

    revoked_resolver = fn current_rule, agent_id, resolver_opts ->
      {:ok, assignment} = AssignmentResolver.resolve(current_rule, agent_id, resolver_opts)
      {:ok, put_in(assignment, [:plugin_package, :status], :revoked)}
    end

    assert {:error, :console_assignment_unavailable} =
             ProxmoxConsoleSessions.attach_with_ticket(ticket,
               session_id: session.id,
               assignment_resolver: revoked_resolver,
               previewer: Previewer,
               actor: @console_actor
             )
  end

  test "browser-supplied credential rule id is ignored while server-selected rule routes the target" do
    uid = unique_uid("agent-scoped-route")
    secret = create_secret!("agent-scoped-route")
    rule = create_rule!(secret, scope_value: "agent-proxmox")
    insert_device!(uid, agent_id: nil, gateway_id: nil, source_rule: rule)
    Process.put(:proxmox_console_test_device_uid, uid)

    assert {:ok, %{session: session}} =
             ProxmoxConsoleSessions.request_open(
               uid,
               %{credential_rule_id: Ecto.UUID.generate()},
               previewer: Previewer,
               assignment_resolver: AssignmentResolver,
               actor: @console_actor
             )

    assert session.agent_id == "agent-proxmox"
  end

  test "guest console uses an explicit console rule and the owning PVE controller" do
    uid = unique_uid("guest-mode")
    controller_uid = unique_uid("guest-controller")
    secret = create_secret!("guest-mode")
    rule = create_rule!(secret, scope_value: "agent-guest")

    host =
      insert_device!(controller_uid,
        agent_id: "agent-guest",
        gateway_id: "gateway-guest",
        hostname: "pve-guest-owner",
        ip: "192.0.2.10",
        cluster: "farm01",
        source_rule: rule
      )

    insert_device!(uid,
      agent_id: nil,
      gateway_id: nil,
      hostname: "guest-workload",
      ip: "198.51.100.126",
      vendor_name: "QEMU",
      metadata: %{}
    )

    _guest = create_virtualization_guest!(uid, host, 155, "farm01")
    Process.put(:proxmox_console_test_device_uid, controller_uid)

    assert {:ok, %{session: session}} =
             ProxmoxConsoleSessions.request_open(
               uid,
               %{target_kind: "lxc_guest", console_mode: "proxmox_termproxy"},
               previewer: Previewer,
               assignment_resolver: AssignmentResolver,
               actor: @console_actor
             )

    assert session.console_mode == :proxmox_termproxy
    assert session.metadata["remote_console"]["target_type"] == "guest"
    assert session.metadata["target"]["device_uid"] == uid
    assert session.metadata["target"]["controller_device_uid"] == controller_uid
    assert session.metadata["target"]["ip"] == "192.0.2.10"
    assert session.metadata["target"]["base_url"] == "https://192.0.2.10:8006"
    assert session.metadata["target"]["node"] == "pve-guest-owner"
    assert session.metadata["target"]["vmid"] == 155
    refute session.metadata["target"]["ip"] == "198.51.100.126"
    assert session.agent_id == "agent-guest"
    assert session.gateway_id == "gateway-guest"
  end

  test "the authorized credential rule selects PVE SSH while browser mode is ignored" do
    uid = unique_uid("ssh-mode")
    secret = create_secret!("ssh-mode")

    rule =
      create_rule!(secret,
        scope_value: "agent-ssh-mode",
        auth_method: :ssh_private_key,
        ssh_host_key_policy: :known_hosts
      )

    insert_device!(uid,
      agent_id: "agent-ssh-mode",
      gateway_id: "gateway-ssh-mode",
      source_rule: rule
    )

    Process.put(:proxmox_console_test_device_uid, uid)

    assert {:ok, %{session: session}} =
             ProxmoxConsoleSessions.request_open(
               uid,
               %{console_mode: "proxmox_termproxy"},
               previewer: Previewer,
               assignment_resolver: AssignmentResolver,
               actor: @console_actor
             )

    assert session.console_mode == :ssh
    assert session.metadata["remote_console"]["protocol"] == "ssh"
    assert session.metadata["remote_console"]["transport"] == "pty"
  end

  test "credential use permission is required independently from console open" do
    actor = %{
      id: Ecto.UUID.generate(),
      role: :viewer,
      permissions: MapSet.new(["devices.view", "devices.console.open"])
    }

    assert {:error, :forbidden} =
             ProxmoxConsoleSessions.request_open("not-used", %{}, actor: actor)
  end

  test "session reads require credential use permission independently from console open" do
    uid = unique_uid("read-permission")
    secret = create_secret!("read-permission")
    rule = create_rule!(secret, scope_value: "agent-read")
    insert_device!(uid, agent_id: "agent-read", gateway_id: "gateway-read", source_rule: rule)
    Process.put(:proxmox_console_test_device_uid, uid)

    assert {:ok, %{session: session}} =
             ProxmoxConsoleSessions.request_open(
               uid,
               %{},
               previewer: Previewer,
               assignment_resolver: AssignmentResolver,
               actor: @console_actor
             )

    actor = %{
      id: Ecto.UUID.generate(),
      role: :viewer,
      permissions: MapSet.new(["devices.console.open"])
    }

    assert {:error,
            %Ash.Error.Invalid{
              errors: [%Ash.Error.Query.NotFound{resource: ProxmoxConsoleSession}]
            }} =
             ProxmoxConsoleSession.get_by_id(session.id, actor: actor)
  end

  test "console rule using gateway scope still requires an agent route for the target device" do
    uid = unique_uid("missing-agent")
    secret = create_secret!("missing-agent")
    rule = create_rule!(secret, scope_type: :gateway, scope_value: "gateway-device")

    insert_device!(uid,
      agent_id: nil,
      gateway_id: "gateway-device",
      source_rule: rule
    )

    Process.put(:proxmox_console_test_device_uid, uid)

    assert {:error, :missing_agent_scope} =
             ProxmoxConsoleSessions.request_open(
               uid,
               %{},
               previewer: Previewer,
               assignment_resolver: AssignmentResolver,
               actor: @console_actor
             )
  end

  test "console rule can use Proxmox discovery agent metadata when agent_id is not populated" do
    uid = unique_uid("metadata-agent")
    secret = create_secret!("metadata-agent")
    rule = create_rule!(secret, scope_value: "agent-from-proxmox-discovery")

    insert_device!(uid,
      agent_id: nil,
      gateway_id: "gateway-metadata",
      metadata: %{"sync_service_id" => "agent-from-proxmox-discovery"},
      source_rule: rule
    )

    Process.put(:proxmox_console_test_device_uid, uid)

    assert {:ok, %{session: session}} =
             ProxmoxConsoleSessions.request_open(
               uid,
               %{},
               previewer: Previewer,
               assignment_resolver: AssignmentResolver,
               actor: @console_actor
             )

    assert session.agent_id == "agent-from-proxmox-discovery"
    assert session.metadata["remote_console"]["agent_id"] == "agent-from-proxmox-discovery"
  end

  test "legacy native host inventory is completed from the matching credential-rule source scope" do
    uid = unique_uid("legacy-host")
    secret = create_secret!("legacy-host")
    rule = create_rule!(secret, scope_value: "agent-legacy-host")

    insert_device!(uid,
      agent_id: "agent-legacy-host",
      gateway_id: "gateway-legacy-host",
      source_rule: rule,
      identity: :legacy
    )

    Process.put(:proxmox_console_test_device_uid, uid)

    assert {:ok, %{session: session}} =
             ProxmoxConsoleSessions.request_open(
               uid,
               %{},
               previewer: Previewer,
               assignment_resolver: AssignmentResolver,
               actor: @console_actor
             )

    assert session.metadata["remote_console"]["target_type"] == "host"
    assert session.metadata["remote_console"]["protocol"] == "proxmox-termproxy"
    assert session.metadata["target"]["identity_version"] == 3
    assert session.metadata["target"]["identity_state"] == "authoritative"
    assert session.metadata["target"]["integration_id"] == rule.integration_id
    assert session.metadata["target"]["controller_id"] == rule.controller_id
  end

  test "system actors cannot substitute for the current console user" do
    assert {:error, :forbidden} =
             ProxmoxConsoleSessions.request_open("not-used", %{}, actor: @system_actor)
  end

  test "console credential rules without an actor-use policy fail closed" do
    uid = unique_uid("missing-use-policy")
    secret = create_secret!("missing-use-policy")

    rule =
      create_rule!(secret, scope_value: "agent-missing-use-policy", metadata: %{})

    insert_device!(uid,
      agent_id: "agent-missing-use-policy",
      gateway_id: "gateway-policy",
      source_rule: rule
    )

    Process.put(:proxmox_console_test_device_uid, uid)

    assert {:error, :no_console_credential_rule} =
             ProxmoxConsoleSessions.request_open(
               uid,
               %{},
               previewer: Previewer,
               assignment_resolver: AssignmentResolver,
               actor: @console_actor
             )
  end

  test "request_open reads the active policy assignment without an explicit resolver" do
    uid = unique_uid("no-resolver-opt")
    secret = create_secret!("no-resolver-opt")
    rule = create_rule!(secret, scope_value: "agent-no-resolver")

    insert_device!(uid,
      agent_id: "agent-no-resolver",
      gateway_id: "gateway-no-resolver",
      source_rule: rule
    )

    Process.put(:proxmox_console_test_device_uid, uid)
    insert_console_package_and_assignment!(rule, "agent-no-resolver")

    assert {:ok, %{session: session}} =
             ProxmoxConsoleSessions.request_open(
               uid,
               %{},
               previewer: Previewer,
               actor: @console_actor
             )

    assert session.agent_id == "agent-no-resolver"
    assert session.credential_rule_id == rule.id
  end

  test "unsupported Proxmox console auth methods are never selected" do
    uid = unique_uid("unsupported-auth")
    secret = create_secret!("unsupported-auth")

    rule =
      create_rule!(secret,
        scope_value: "agent-unsupported-auth",
        auth_method: :certificate
      )

    insert_device!(uid,
      agent_id: "agent-unsupported-auth",
      gateway_id: "gateway-unsupported-auth",
      source_rule: rule
    )

    Process.put(:proxmox_console_test_device_uid, uid)

    assert {:error, :no_console_credential_rule} =
             ProxmoxConsoleSessions.request_open(
               uid,
               %{},
               previewer: Previewer,
               assignment_resolver: AssignmentResolver,
               actor: @console_actor
             )
  end

  defp insert_device!(uid, opts) do
    now = DateTime.utc_now()
    vendor_name = Keyword.get(opts, :vendor_name, "Proxmox")
    hostname = Keyword.get(opts, :hostname, uid)
    proxmox? = String.contains?(String.downcase(vendor_name), "proxmox")
    source_rule = if proxmox?, do: Keyword.fetch!(opts, :source_rule)
    cluster = Keyword.get(opts, :cluster, "test-cluster")

    identity_mode = Keyword.get(opts, :identity, :authoritative)

    identity =
      if proxmox? and identity_mode != :legacy do
        proxmox_identity!(source_rule, cluster, "node", hostname)
      end

    metadata =
      opts
      |> Keyword.get(:metadata, %{})
      |> authoritative_device_metadata(identity)

    ip = Keyword.get(opts, :ip, if(proxmox?, do: "192.0.2.10"))

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: hostname,
        ip: ip,
        vendor_name: vendor_name,
        agent_id: Keyword.get(opts, :agent_id),
        gateway_id: Keyword.get(opts, :gateway_id),
        is_available: true,
        metadata: metadata,
        first_seen_time: now,
        last_seen_time: now
      }
    ])

    if proxmox? do
      if identity do
        create_virtualization_host!(uid, hostname, identity)
      else
        create_legacy_virtualization_host!(uid, hostname, cluster)
      end
    end
  end

  defp create_virtualization_host!(device_uid, node, identity) do
    VirtualizationHost
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(identity, %{
        provider: "proxmox",
        device_uid: device_uid,
        name: node,
        metadata: %{}
      })
    )
    |> Ash.create!(actor: @system_actor)
  end

  defp create_legacy_virtualization_host!(device_uid, node, cluster) do
    # Model a row that predates the v3 insert guard; restore the guard before opening the console.
    Repo.query!(
      "ALTER TABLE platform.virtualization_hosts DISABLE TRIGGER virtualization_hosts_identity_immutable_guard"
    )

    try do
      VirtualizationHost
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider: "proxmox",
          provider_ref: "proxmox:node:#{node}",
          device_uid: device_uid,
          name: node,
          identity_state: :legacy,
          native_cluster_id: cluster,
          object_kind: "node",
          native_object_id: node,
          metadata: %{}
        }
      )
      |> Ash.create!(actor: @system_actor)
    after
      Repo.query!(
        "ALTER TABLE platform.virtualization_hosts ENABLE TRIGGER virtualization_hosts_identity_immutable_guard"
      )
    end
  end

  defp create_virtualization_guest!(device_uid, host, vmid, _cluster) do
    identity = proxmox_identity!(host, host.native_cluster_id, "lxc", vmid)

    VirtualizationGuest
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(identity, %{
        provider: "proxmox",
        host_id: host.id,
        device_uid: device_uid,
        name: "guest-#{vmid}",
        guest_type: "lxc",
        vmid: vmid,
        metadata: %{}
      })
    )
    |> Ash.create!(actor: @system_actor)
  end

  defp proxmox_identity!(source, cluster, object_kind, native_object_id) do
    {:ok, identity} =
      IntegrationIdentity.proxmox_v3_fields(
        source.integration_id,
        source.controller_id,
        cluster,
        object_kind,
        native_object_id
      )

    identity
  end

  defp authoritative_device_metadata(metadata, nil), do: metadata

  defp authoritative_device_metadata(metadata, identity) do
    Map.merge(metadata, %{
      "provider_ref" => identity.provider_ref,
      "provider_instance_ref" => identity.provider_instance_ref,
      "integration_id" => identity.integration_id,
      "controller_id" => identity.controller_id,
      "native_cluster_id" => identity.native_cluster_id
    })
  end

  defp insert_console_actor! do
    now = DateTime.utc_now()
    profile_id = "018f3f56-2222-7666-8777-123456789abc"

    Repo.insert_all("role_profiles", [
      %{
        id: Ecto.UUID.dump!(profile_id),
        system_name: nil,
        name: "Proxmox Console Test Operator",
        description: "Persistence-backed authority for console boundary tests",
        permissions: MapSet.to_list(@console_actor.permissions),
        system: false,
        inserted_at: now,
        updated_at: now
      }
    ])

    Repo.insert_all("ng_users", [
      %{
        id: Ecto.UUID.dump!(@console_actor.id),
        email: @console_actor.email,
        display_name: "Console Operator",
        role: "admin",
        role_profile_id: Ecto.UUID.dump!(profile_id),
        inserted_at: now,
        updated_at: now
      }
    ])
  end

  defp create_secret!(suffix) do
    {:ok, secret} =
      NetworkCredentialSecret
      |> Ash.Changeset.for_create(:create, %{
        name: "pve-console-#{suffix}-#{System.unique_integer([:positive])}",
        provider: "proxmox",
        credential_kind: :api_token,
        username: "root@pam!sr",
        secret_payload: "root@pam!sr=test-token",
        metadata: %{"auth_method" => "proxmox_api_token"}
      })
      |> Ash.create(actor: @system_actor)

    secret
  end

  defp create_rule!(secret, attrs) do
    {:ok, rule} =
      NetworkCredentialRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "pve-console-rule-#{System.unique_integer([:positive])}",
          provider: "proxmox",
          auth_method: Keyword.get(attrs, :auth_method, :proxmox_api_token),
          purpose: :console_access,
          target_query: "in:devices",
          scope_type: Keyword.get(attrs, :scope_type, :agent),
          scope_value: Keyword.fetch!(attrs, :scope_value),
          secret_id: secret.id,
          tls_policy: Keyword.get(attrs, :tls_policy, :verify),
          ssh_host_key_policy: Keyword.get(attrs, :ssh_host_key_policy, :known_hosts),
          metadata:
            Keyword.get(attrs, :metadata, %{
              "credential_use_policy" => %{
                "schema" => CredentialUsePolicy.schema(),
                "roles" => ["admin"]
              }
            })
        }
      )
      |> Ash.create(actor: @system_actor)

    rule
  end

  defp insert_console_package_and_assignment!(rule, agent_uid) do
    now = DateTime.utc_now()
    package_id = Ecto.UUID.generate()
    policy_id = "network-credential-rule:#{rule.id}:console_access"

    Repo.insert_all("plugins", [
      %{
        plugin_id: "proxmox-console",
        name: "proxmox-console-test-plugin",
        inserted_at: now,
        updated_at: now
      }
    ])

    Repo.insert_all("plugin_packages", [
      %{
        id: Ecto.UUID.dump!(package_id),
        plugin_id: "proxmox-console",
        name: "proxmox-console-test-package",
        version: "1.0.0",
        entrypoint: "run_console",
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
        id: Ecto.UUID.dump!(Ecto.UUID.generate()),
        agent_uid: agent_uid,
        partition_id: "test-partition",
        plugin_id: "proxmox-console",
        plugin_package_id: Ecto.UUID.dump!(package_id),
        source: "policy",
        policy_id: policy_id,
        enabled: true,
        params: %{
          "policy_id" => policy_id,
          "policy_version" => 1,
          "credential_rule_id" => to_string(rule.id)
        },
        inserted_at: now,
        updated_at: now
      }
    ])

    :ok
  end

  defp unique_uid(label), do: "pve-console-#{label}-#{System.unique_integer([:positive])}"

  defp private_key_fixture do
    private_key_fixture_header() <>
      """
      b3BlbnNzaC10ZXN0LWtleS1tYXRlcmlhbA==
      #{private_key_fixture_footer()}
      """
  end

  defp private_key_fixture_header, do: "-----BEGIN OPENSSH " <> "PRIVATE KEY-----\n"
  defp private_key_fixture_footer, do: "-----END OPENSSH " <> "PRIVATE KEY-----"
end
