defmodule ServiceRadar.Edge.RemoteAccessDefectsUnitTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialUsePolicy
  alias ServiceRadar.Edge.ProxmoxConsoleSessions
  alias ServiceRadar.Edge.RemoteAccessBroker
  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadar.Edge.RemoteAccessSessions

  defmodule CommandBusStub do
    @moduledoc false
    def send_console_frame(agent_id, frame, opts) do
      send(Keyword.fetch!(opts, :required_gateway_node), {:send_console_frame, agent_id, frame})
      :ok
    end
  end

  defmodule PubSubStub do
    @moduledoc false
    def subscribe(_session_id), do: :ok
  end

  defmodule BrokerRegistryStub do
    @moduledoc false
    def register(_session_id, _meta), do: :ok
    def unregister(_session_id), do: :ok
  end

  defmodule RecordingsStub do
    @moduledoc false
    def ensure_for_session(_session, _opts), do: {:ok, nil}
    def activate(_recording, _opts), do: {:ok, nil}
    def complete(_recording, _attrs, _opts), do: {:ok, nil}
    def fail(_recording, _reason, _attrs, _opts), do: {:ok, nil}
    def record_event(_recording, _attrs, _opts), do: {:ok, nil}
  end

  defmodule AuditWriterStub do
    @moduledoc false
    def write_async(_attrs), do: :ok
  end

  defmodule LifecycleSpy do
    @moduledoc false

    def mark_opening(session_id, opts) do
      notify(session_id, {:lifecycle, :mark_opening, session_id, opts})
      :ok
    end

    def activate_session(session_id, opts) do
      notify(session_id, {:lifecycle, :activate_session, session_id, opts})
      :ok
    end

    def request_close(session_id, opts) do
      notify(session_id, {:lifecycle, :request_close, session_id, opts})
      :ok
    end

    def close_session(session_id, opts) do
      notify(session_id, {:lifecycle, :close_session, session_id, opts})
      :ok
    end

    def fail_session(session_id, reason, opts \\ []) do
      notify(session_id, {:lifecycle, :fail_session, session_id, reason, opts})
      :ok
    end

    defp notify("spy:" <> pid_str, msg) do
      pid = :erlang.list_to_pid(String.to_charlist(pid_str))
      send(pid, msg)
    end
  end

  defmodule PreviewStub do
    @moduledoc false

    def preview_rule(rule, _opts) do
      matched = MapSet.new(Map.get(rule, :test_matched_uids, []))
      scoped = MapSet.new(Map.get(rule, :test_scoped_uids, []))

      {:ok,
       %{
         rule_id: to_string(rule.id),
         matched_devices: MapSet.size(matched),
         scoped_devices: MapSet.size(scoped),
         matched_device_uids: matched,
         scoped_device_uids: scoped,
         agents: [],
         sample_devices: Enum.map(scoped, &%{uid: &1}),
         conflicts: []
       }}
    end
  end

  describe "Defect 4: RemoteAccessSession closing -> expired and broker close completion" do
    test "RemoteAccessSession :expire action accepts :closing rows and preserves close_reason" do
      closing_session = %RemoteAccessSession{
        id: Ecto.UUID.generate(),
        status: :closing,
        attach_ticket_hash: "synthetic-hash",
        attach_expires_at: ~U[2026-07-01 00:05:00Z],
        target_kind: :inventory_device,
        target_host: "host.example.test",
        target_port: 22,
        protocol: :ssh,
        adapter: :ssh,
        agent_id: "agent-a",
        gateway_id: "gateway-a",
        credential_custody_mode: :none,
        rbac_decision: :allowed,
        close_requested_at: ~U[2026-07-01 00:01:00Z],
        close_reason: "browser_disconnected",
        metadata: %{}
      }

      changeset =
        Ash.Changeset.for_update(
          closing_session,
          :expire,
          %{outcome: :idle_timeout},
          actor: SystemActor.system(:test_expire)
        )

      assert changeset.valid?,
             "expected :expire from :closing to be valid, got errors: #{inspect(changeset.errors)}"

      assert Ash.Changeset.get_attribute(changeset, :status) == :expired
      assert Ash.Changeset.get_attribute(changeset, :close_reason) == "browser_disconnected"
      assert %DateTime{} = Ash.Changeset.get_attribute(changeset, :closed_at)
    end

    test "RemoteAccessBroker.close completes close_session instead of leaving session in closing" do
      session_id = "spy:" <> List.to_string(:erlang.pid_to_list(self()))
      session = broker_session_struct(session_id)

      {:ok, pid} =
        RemoteAccessBroker.start_link(
          session,
          self(),
          command_bus: CommandBusStub,
          pubsub: PubSubStub,
          broker_registry: BrokerRegistryStub,
          recordings: RecordingsStub,
          audit_writer: AuditWriterStub,
          lifecycle: LifecycleSpy,
          required_gateway_node: self(),
          metadata: ssh_grant()
        )

      assert_receive {:lifecycle, :mark_opening, ^session_id, _}

      ref = Process.monitor(pid)
      assert :ok = RemoteAccessBroker.close(pid, "browser_disconnected")
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      assert_receive {:lifecycle, :close_session, ^session_id, close_opts}
      assert close_opts[:reason] == "browser_disconnected"
    end

    test "RemoteAccessBroker normal shutdown without prior close completes close_session in terminate" do
      session_id = "spy:" <> List.to_string(:erlang.pid_to_list(self()))
      session = broker_session_struct(session_id)

      {:ok, pid} =
        RemoteAccessBroker.start_link(
          session,
          self(),
          command_bus: CommandBusStub,
          pubsub: PubSubStub,
          broker_registry: BrokerRegistryStub,
          recordings: RecordingsStub,
          audit_writer: AuditWriterStub,
          lifecycle: LifecycleSpy,
          required_gateway_node: self(),
          metadata: ssh_grant()
        )

      assert_receive {:lifecycle, :mark_opening, ^session_id, _}

      :ok = GenServer.stop(pid, :normal)

      assert_receive {:lifecycle, :close_session, ^session_id, close_opts}
      assert close_opts[:reason] == "normal"
    end

    test "RemoteAccessSessions.stale_session_expiry classifies stuck closing, expired requested, and stale active rows" do
      now = ~U[2026-07-01 12:00:00Z]

      stuck_closing = %RemoteAccessSession{
        id: Ecto.UUID.generate(),
        status: :closing,
        close_requested_at: ~U[2026-07-01 11:58:00Z],
        close_reason: "browser_disconnected",
        attach_expires_at: ~U[2026-07-01 11:50:00Z],
        idle_timeout_seconds: 900,
        absolute_timeout_seconds: 3600,
        inserted_at: ~U[2026-07-01 11:45:00Z],
        updated_at: ~U[2026-07-01 11:58:00Z]
      }

      fresh_closing = %{stuck_closing | close_requested_at: ~U[2026-07-01 11:59:45Z]}

      expired_requested = %RemoteAccessSession{
        id: Ecto.UUID.generate(),
        status: :requested,
        attach_expires_at: ~U[2026-07-01 11:59:00Z],
        idle_timeout_seconds: 900,
        absolute_timeout_seconds: 3600,
        inserted_at: ~U[2026-07-01 11:58:00Z],
        updated_at: ~U[2026-07-01 11:58:00Z]
      }

      stale_attached = %RemoteAccessSession{
        id: Ecto.UUID.generate(),
        status: :attached,
        attach_expires_at: ~U[2026-07-01 10:01:00Z],
        attached_at: ~U[2026-07-01 10:00:30Z],
        last_activity_at: ~U[2026-07-01 10:00:30Z],
        idle_timeout_seconds: 900,
        absolute_timeout_seconds: 3600,
        inserted_at: ~U[2026-07-01 10:00:00Z],
        updated_at: ~U[2026-07-01 10:00:30Z]
      }

      assert {:expire, "browser_disconnected", :idle_timeout} =
               RemoteAccessSessions.stale_session_expiry(stuck_closing, now,
                 closing_grace_seconds: 60
               )

      assert :fresh ==
               RemoteAccessSessions.stale_session_expiry(fresh_closing, now,
                 closing_grace_seconds: 60
               )

      assert {:expire, "attach_expired", :idle_timeout} =
               RemoteAccessSessions.stale_session_expiry(expired_requested, now,
                 closing_grace_seconds: 60
               )

      assert {:expire, "idle_timeout", :idle_timeout} =
               RemoteAccessSessions.stale_session_expiry(stale_attached, now,
                 closing_grace_seconds: 60
               )
    end
  end

  describe "Defect 12: ProxmoxConsoleSessions specific rule denial classification and RBAC gating" do
    test "classifies each candidate rule failure specifically and chooses nearest candidate on mismatch" do
      target = sample_target()
      device = target.controller.device

      console_only_opts = [
        previewer: PreviewStub,
        actor: %{
          id: Ecto.UUID.generate(),
          role: :operator,
          permissions: MapSet.new(["devices.console.open", "devices.console.credentials.use"])
        }
      ]

      assert {:error, :no_console_credential_rule} =
               ProxmoxConsoleSessions.evaluate_console_candidate_rules(
                 [],
                 target,
                 device,
                 console_only_opts
               )

      source_mismatch_rule = candidate_rule(integration_id: "other-integration")

      assert {:error, :console_credential_source_mismatch} =
               ProxmoxConsoleSessions.evaluate_console_candidate_rules(
                 [source_mismatch_rule],
                 target,
                 device,
                 console_only_opts
               )

      inventory_only_rule = candidate_rule(purpose: :inventory_enrichment, metadata: %{})

      assert {:error, :not_console_credential_rule} =
               ProxmoxConsoleSessions.evaluate_console_candidate_rules(
                 [inventory_only_rule],
                 target,
                 device,
                 console_only_opts
               )

      no_tls_verify_rule = candidate_rule(tls_policy: "insecure_skip_verify")

      assert {:error, :proxmox_tls_verification_required} =
               ProxmoxConsoleSessions.evaluate_console_candidate_rules(
                 [no_tls_verify_rule],
                 target,
                 device,
                 console_only_opts
               )

      target_miss_rule = candidate_rule(test_matched_uids: [], test_scoped_uids: [])

      assert {:error, :credential_rule_target_denied} =
               ProxmoxConsoleSessions.evaluate_console_candidate_rules(
                 [target_miss_rule],
                 target,
                 device,
                 console_only_opts
               )

      scope_miss_rule =
        candidate_rule(
          scope_type: :agent,
          scope_value: "agent-other",
          test_matched_uids: [device.uid],
          test_scoped_uids: []
        )

      assert {:error, :credential_rule_scope_denied} =
               ProxmoxConsoleSessions.evaluate_console_candidate_rules(
                 [scope_miss_rule],
                 target,
                 device,
                 console_only_opts
               )

      denied_policy = %{
        "purposes" => ["console_access"],
        "credential_use_policy" => %{
          "schema" => CredentialUsePolicy.schema(),
          "roles" => ["super_admin"]
        }
      }

      policy_denied_rule = candidate_rule(metadata: denied_policy)

      # Nearest-miss selection: when an inventory_enrichment rule comes before a console_access
      # rule that fails at actor-use policy, the console_access rule is closer and wins.
      assert {:error, :credential_use_policy_denied} =
               ProxmoxConsoleSessions.evaluate_console_candidate_rules(
                 [inventory_only_rule, policy_denied_rule],
                 target,
                 device,
                 console_only_opts
               )
    end

    test "attaches sanitized rule detail only when caller holds settings.credentials.manage" do
      target = sample_target()
      device = target.controller.device

      rule =
        candidate_rule(
          id: "018f3f56-1111-7666-8777-123456789abc",
          name: "sentinel-proxmox-rule-alpha",
          scope_type: :agent,
          scope_value: "agent-alpha",
          target_query: "in:devices hostname:sentinel-pve-node",
          secret_id: "018f3f56-9999-7666-8777-secret000000",
          purpose: :inventory_enrichment,
          metadata: %{"note" => "internal-operator-note"}
        )

      non_manager_opts = [
        previewer: PreviewStub,
        scope: %{
          user: %{id: Ecto.UUID.generate(), role: :operator},
          permissions: MapSet.new(["devices.console.open", "devices.console.credentials.use"])
        }
      ]

      non_manager_result =
        ProxmoxConsoleSessions.evaluate_console_candidate_rules(
          [rule],
          target,
          device,
          non_manager_opts
        )

      assert {:error, :not_console_credential_rule} = non_manager_result
      refute inspect(non_manager_result) =~ "sentinel-proxmox-rule-alpha"
      refute inspect(non_manager_result) =~ "sentinel-pve-node"

      manager_opts = [
        previewer: PreviewStub,
        scope: %{
          user: %{id: Ecto.UUID.generate(), role: :admin},
          permissions:
            MapSet.new([
              "devices.console.open",
              "devices.console.credentials.use",
              "settings.credentials.manage"
            ])
        }
      ]

      assert {:error, {:console_rule_denied, :not_console_credential_rule, detail}} =
               ProxmoxConsoleSessions.evaluate_console_candidate_rules(
                 [rule],
                 target,
                 device,
                 manager_opts
               )

      assert detail == %{
               rule_id: "018f3f56-1111-7666-8777-123456789abc",
               rule_name: "sentinel-proxmox-rule-alpha",
               scope_type: "agent",
               scope_value: "agent-alpha",
               target_query: "in:devices hostname:sentinel-pve-node"
             }

      refute Map.has_key?(detail, :secret_id)
      refute inspect(detail) =~ "secret000000"
      refute inspect(detail) =~ "internal-operator-note"
    end
  end

  defp broker_session_struct(session_id) do
    %RemoteAccessSession{
      id: session_id,
      status: :attached,
      attach_ticket_hash: "synthetic-ticket-hash",
      attach_expires_at: ~U[2026-07-01 01:00:00Z],
      device_uid: "device-synth-1",
      target_kind: :inventory_device,
      target_host: "192.0.2.25",
      target_port: 22,
      protocol: :ssh,
      adapter: :ssh,
      agent_id: "agent-synth-1",
      gateway_id: "gateway-synth-1",
      credential_custody_mode: :user_present,
      rbac_decision: :allowed,
      idle_timeout_seconds: 900,
      absolute_timeout_seconds: 3600,
      metadata: %{
        "target" => %{
          "device_uid" => "device-synth-1",
          "host" => "192.0.2.25",
          "port" => 22
        },
        "ssh_host_key_policy" => "known_hosts",
        "ssh_known_host_keys" => [
          "192.0.2.25 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILM+rvN+ot98qgEN796jTiQfZfG1KaT0PtFDJ/XFSqti"
        ]
      }
    }
  end

  defp ssh_grant do
    %{
      "ssh" => %{
        "username" => "ops",
        "private_key" => "synthetic-private-key",
        "certificate" => "synthetic-cert"
      }
    }
  end

  defp sample_target do
    device = %{
      uid: "sr:pve-host-synth-1",
      agent_id: "agent-alpha",
      gateway_id: "gateway-alpha",
      metadata: %{"partition_id" => "partition-alpha"}
    }

    %{
      target_kind: :pve_host,
      console_mode: :proxmox_termproxy,
      integration_id: "integration-alpha",
      controller_id: "controller-alpha",
      controller: %{
        device_uid: device.uid,
        device: device,
        gateway_id: "gateway-alpha",
        hostname: "pve-alpha.example.test",
        ip: "192.0.2.40",
        base_url: "https://192.0.2.40:8006",
        provider_ref: "pve-alpha",
        integration_id: "integration-alpha",
        provider_instance_ref: "instance-alpha",
        virtualization_host_id: "vhost-alpha",
        native_cluster_id: "cluster-alpha",
        native_object_id: "node/pve-alpha",
        ssh_port: 22
      },
      provider_instance_ref: "instance-alpha",
      identity_version: 3,
      identity_state: :authoritative,
      native_cluster_id: "cluster-alpha",
      object_kind: "node",
      native_object_id: "node/pve-alpha",
      inventory_row_id: "row-alpha",
      owner_host_id: "vhost-alpha",
      cluster: "cluster-alpha",
      node: "pve-alpha",
      vmid: nil
    }
  end

  defp candidate_rule(overrides) do
    default_metadata = %{
      "purposes" => ["console_access"],
      "credential_use_policy" => %{
        "schema" => CredentialUsePolicy.schema(),
        "roles" => ["operator", "admin"]
      }
    }

    base = %{
      id: Ecto.UUID.generate(),
      name: "proxmox-console-rule",
      provider: "proxmox",
      purpose: :console_access,
      enabled: true,
      priority: 100,
      scope_type: :agent,
      scope_value: "agent-alpha",
      target_query: "in:devices uid:sr:pve-host-synth-1",
      auth_method: "proxmox_api_token",
      tls_policy: "verify",
      ssh_host_key_policy: "known_hosts",
      integration_id: "integration-alpha",
      controller_id: "controller-alpha",
      secret_id: Ecto.UUID.generate(),
      metadata: default_metadata,
      test_matched_uids: ["sr:pve-host-synth-1"],
      test_scoped_uids: ["sr:pve-host-synth-1"]
    }

    Map.merge(base, Map.new(overrides))
  end
end
