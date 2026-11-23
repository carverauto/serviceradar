defmodule ServiceRadar.Jobs.SettingsBackupCollectorAndDestinationTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Jobs.SettingsBackup.Collector
  alias ServiceRadar.Jobs.SettingsBackupDestination

  @synthetic_secret_value "synthetic-plaintext-secret-must-never-leak"
  @synthetic_ciphertext "synthetic-encrypted-ciphertext-bytes"

  setup do
    if is_nil(Process.whereis(ServiceRadar.Vault)) do
      start_supervised!(ServiceRadar.Vault)
    end

    :ok
  end

  describe "Collector.collect/1" do
    test "produces deterministic canonical JSON and excludes all secret payloads" do
      exported_at = ~U[2026-11-22 12:00:00Z]

      readers_a = build_synthetic_readers(:order_a)
      readers_b = build_synthetic_readers(:order_b)

      assert {:ok, snap_a} =
               Collector.collect(
                 exported_at: exported_at,
                 reason: "manual",
                 readers: readers_a
               )

      assert {:ok, snap_b} =
               Collector.collect(
                 exported_at: exported_at,
                 reason: "manual",
                 readers: readers_b
               )

      assert snap_a.json == snap_b.json
      assert snap_a.sha256 == snap_b.sha256
      assert byte_size(snap_a.sha256) == 64
      assert snap_a.sha256_prefix == binary_part(snap_a.sha256, 0, 12)

      refute String.contains?(snap_a.json, @synthetic_secret_value)
      refute String.contains?(snap_a.json, @synthetic_ciphertext)
      refute String.contains?(snap_a.json, "values_wo")
      refute String.contains?(snap_a.json, "secret_payload")
      refute String.contains?(snap_a.json, "community_encrypted")
      refute String.contains?(snap_a.json, "auth_password")
      refute String.contains?(snap_a.json, "priv_password")
      refute String.contains?(snap_a.json, "inline-meta-secret")
      refute String.contains?(snap_a.json, "inline-meta-token")
      refute String.contains?(snap_a.json, "inline-meta-password")
      refute String.contains?(snap_a.json, "inline-meta-key")

      decoded = Jason.decode!(snap_a.json)
      assert decoded["schema_version"] == 1
      assert decoded["exported_at"] == "2026-11-22T12:00:00Z"
      assert decoded["reason"] == "manual"

      tf = decoded["terraform_resources"]

      assert [secret_one, secret_two] = tf["serviceradar_network_credential_secret"]
      assert secret_one["id"] == "00000000-0000-4000-8000-000000000001"
      assert secret_two["id"] == "00000000-0000-4000-8000-000000000002"
      assert secret_one["credential_provider"] == "awx"
      assert secret_one["auth_method"] == "bearer_token"
      assert secret_one["values_version"] == 1
      assert secret_one["metadata"] == %{"auth_method" => "bearer_token", "env" => "lab"}

      assert [rule] = tf["serviceradar_network_credential_rule"]
      assert rule["credential_provider"] == "awx"
      assert rule["allowed_ports"] == [443, 8443]
      assert rule["secret_id"] == "00000000-0000-4000-8000-000000000001"

      assert [controller] = tf["serviceradar_ansible_controller"]
      assert controller["base_url"] == "https://awx.example.com"
      assert controller["sync_credential_secret_id"] == "00000000-0000-4000-8000-000000000001"

      assert [repo] = tf["serviceradar_ansible_repository"]
      assert repo["git_url"] == "https://git.example.com/org/playbooks.git"

      settings = decoded["settings"]
      assert [snmp] = settings["snmp_profiles"]
      assert snmp["credential_secret_id"] == "00000000-0000-4000-8000-000000000001"
      assert snmp["oid_template_ids"] == ["oid-a", "oid-b"]
      assert snmp["agent_ids"] == ["agent-1", "agent-2"]

      assert [mail] = settings["outbound_mail_settings"]
      assert mail["password_present"] == true
      assert mail["api_key_present"] == false
      assert mail["password_secret_id"] == "00000000-0000-4000-8000-000000000001"

      assert [netflow] = settings["netflow_settings"]
      assert netflow["ipinfo_api_key_present"] == true

      assert [mapbox] = settings["mapbox_settings"]
      assert mapbox["access_token_present"] == true
    end
  end

  describe "SettingsBackupDestination validation and AshOban trigger" do
    test "validates HTTPS endpoints without userinfo, path, query, or fragment" do
      assert {:ok, "https://us-east-1.linodeobjects.com"} =
               SettingsBackupDestination.normalize_https_endpoint(
                 "https://us-east-1.linodeobjects.com/"
               )

      assert {:ok, "https://127.0.0.1:8443"} =
               SettingsBackupDestination.normalize_https_endpoint(" https://127.0.0.1:8443 ")

      for invalid <- [
            "http://us-east-1.linodeobjects.com",
            "https://user:pass@us-east-1.linodeobjects.com",
            "https://us-east-1.linodeobjects.com/bucket",
            "https://us-east-1.linodeobjects.com?foo=bar",
            "https://us-east-1.linodeobjects.com#frag",
            "not-a-url",
            ""
          ] do
        assert {:error, _} = SettingsBackupDestination.normalize_https_endpoint(invalid),
               "expected invalid endpoint: #{inspect(invalid)}"
      end
    end

    test "normalizes prefixes and rejects traversal segments" do
      assert {:ok, ""} = SettingsBackupDestination.normalize_prefix("")
      assert {:ok, ""} = SettingsBackupDestination.normalize_prefix("///")

      assert {:ok, "tenant-a/prod"} =
               SettingsBackupDestination.normalize_prefix("/tenant-a/prod/")

      assert {:error, _} = SettingsBackupDestination.normalize_prefix("../escape")
      assert {:error, _} = SettingsBackupDestination.normalize_prefix("a//b")
      assert {:error, _} = SettingsBackupDestination.normalize_prefix("a/./b")
    end

    test "create changeset requires credentials, valid cron, non-empty bucket/region, and sets next_run_at" do
      invalid_cs =
        Ash.Changeset.for_create(SettingsBackupDestination, :create, %{
          enabled: true,
          endpoint: "http://insecure.example.com",
          bucket: "",
          region: "",
          schedule_cron: "not-a-cron"
        })

      refute invalid_cs.valid?
      fields = Enum.map(invalid_cs.errors, & &1.field)
      assert :endpoint in fields
      assert :bucket in fields
      assert :region in fields
      assert :schedule_cron in fields
      assert :access_key_id in fields
      assert :secret_access_key in fields

      valid_cs =
        Ash.Changeset.for_create(SettingsBackupDestination, :create, %{
          enabled: true,
          endpoint: "https://us-east-1.linodeobjects.com/",
          bucket: "synthetic-backup-bucket",
          region: "us-east-1",
          prefix: "/tenant-synthetic/",
          schedule_cron: "0 */6 * * *",
          access_key_id: "AKIA_SYNTHETIC_KEY",
          secret_access_key: "synthetic-secret-key"
        })

      assert valid_cs.valid?

      assert Ash.Changeset.get_attribute(valid_cs, :endpoint) ==
               "https://us-east-1.linodeobjects.com"

      assert Ash.Changeset.get_attribute(valid_cs, :prefix) == "tenant-synthetic"
      assert is_binary(Ash.Changeset.get_attribute(valid_cs, :encrypted_access_key_id))
      assert is_binary(Ash.Changeset.get_attribute(valid_cs, :encrypted_secret_access_key))
      assert %DateTime{} = Ash.Changeset.get_attribute(valid_cs, :next_run_at)
    end

    test "update changeset preserves existing encrypted credentials when omitted" do
      existing = %SettingsBackupDestination{
        id: Ecto.UUID.generate(),
        key: "default",
        enabled: true,
        provider: "linode_object_storage",
        endpoint: "https://us-east-1.linodeobjects.com",
        bucket: "synthetic-backup-bucket",
        region: "us-east-1",
        prefix: "",
        schedule_cron: "0 */6 * * *",
        encrypted_access_key_id: <<1, 2, 3>>,
        encrypted_secret_access_key: <<4, 5, 6>>
      }

      cs =
        Ash.Changeset.for_update(existing, :update, %{
          enabled: false,
          schedule_cron: "15 */12 * * *"
        })

      assert cs.valid?
      assert is_nil(Ash.Changeset.get_attribute(cs, :next_run_at))
    end

    test "exposes priority-0 AshOban export trigger on :maintenance queue" do
      [trigger] = AshOban.Info.oban_triggers(SettingsBackupDestination)
      assert trigger.name == :export
      assert trigger.queue == :maintenance
      assert trigger.scheduler_priority == 0
      assert trigger.worker_priority == 0
      assert trigger.read_action == :due
      assert trigger.worker_read_action == :read
      assert trigger.action == :run
      assert trigger.scheduler_cron == "* * * * *"

      assert trigger.scheduler_module_name ==
               ServiceRadar.Jobs.SettingsBackupDestination.ExportScheduler

      assert trigger.worker_module_name ==
               ServiceRadar.Jobs.SettingsBackupDestination.ExportWorker
    end
  end

  defp build_synthetic_readers(order) do
    secret_one = %{
      id: "00000000-0000-4000-8000-000000000001",
      name: "AWX Token",
      description: "Synthetic AWX token",
      provider: "awx",
      credential_kind: :api_token,
      username: nil,
      public_fingerprint: "sha256:synthetic1",
      managed_by: :operator,
      credential_generation: nil,
      source_type: :internal,
      rotation_state: :active,
      last_rotated_at: ~U[2026-11-20 00:00:00Z],
      secret_payload: @synthetic_secret_value,
      encrypted_secret_payload: @synthetic_ciphertext,
      metadata: %{
        "auth_method" => "bearer_token",
        "env" => "lab",
        "secret" => "inline-meta-secret",
        "token" => "inline-meta-token",
        "password" => "inline-meta-password",
        "private_key" => "inline-meta-key"
      }
    }

    secret_two = %{
      id: "00000000-0000-4000-8000-000000000002",
      name: "Git Token",
      description: nil,
      provider: "git",
      credential_kind: :api_token,
      username: "git-bot",
      public_fingerprint: "sha256:synthetic2",
      managed_by: :operator,
      credential_generation: nil,
      source_type: :internal,
      rotation_state: :active,
      last_rotated_at: nil,
      metadata: %{"auth_method" => "bearer_token"}
    }

    secrets = if order == :order_a, do: [secret_one, secret_two], else: [secret_two, secret_one]

    %{
      network_credential_secrets: fn _actor -> secrets end,
      network_credential_rules: fn _actor ->
        [
          %{
            id: "10000000-0000-4000-8000-000000000001",
            name: "AWX Rule",
            description: "Rule",
            provider: "awx",
            auth_method: "bearer_token",
            purpose: "automation",
            target_query: "in:devices",
            scope_type: :global,
            scope_value: "",
            secret_id: "00000000-0000-4000-8000-000000000001",
            allowed_ports: if(order == :order_a, do: [8443, 443], else: [443, 8443]),
            tls_policy: :verify,
            ssh_host_key_policy: :known_hosts,
            ca_bundle_pem: nil,
            server_cert_fingerprint: nil,
            priority: 100,
            enabled: true,
            metadata: %{}
          }
        ]
      end,
      ansible_controllers: fn _actor ->
        [
          %{
            id: "20000000-0000-4000-8000-000000000001",
            name: "Primary AWX",
            description: "Synthetic controller",
            base_url: "https://awx.example.com",
            agent_id: "agent-1",
            sync_credential_secret_id: "00000000-0000-4000-8000-000000000001",
            execution_credential_secret_id: nil,
            callback_credential_secret_id: nil,
            inventory_sync_interval_seconds: 300,
            catalog_sync_interval_seconds: 600,
            enabled: true,
            status: :unknown,
            awx_version: nil,
            metadata: %{}
          }
        ]
      end,
      ansible_repositories: fn _actor ->
        [
          %{
            id: "30000000-0000-4000-8000-000000000001",
            name: "Playbooks",
            description: nil,
            git_url: "https://git.example.com/org/playbooks.git",
            git_ref: "main",
            sync_interval_seconds: 600,
            credential_secret_id: nil,
            last_sync_status: :pending,
            last_sync_at: nil,
            metadata: %{}
          }
        ]
      end,
      snmp_profiles: fn _actor ->
        [
          %{
            id: "40000000-0000-4000-8000-000000000001",
            name: "Core SNMP",
            description: "SNMPv3 profile",
            poll_interval: 60,
            timeout: 5,
            retries: 3,
            is_default: true,
            enabled: true,
            target_query: "in:devices",
            priority: 10,
            version: :v3,
            username: "snmp-ro",
            security_level: :auth_priv,
            auth_protocol: :sha256,
            priv_protocol: :aes128,
            credential_secret_id: "00000000-0000-4000-8000-000000000001",
            community_encrypted: @synthetic_ciphertext,
            auth_password_encrypted: @synthetic_ciphertext,
            priv_password_encrypted: @synthetic_ciphertext,
            oid_template_ids:
              if(order == :order_a, do: ["oid-b", "oid-a"], else: ["oid-a", "oid-b"]),
            agent_ids:
              if(order == :order_a, do: ["agent-2", "agent-1"], else: ["agent-1", "agent-2"])
          }
        ]
      end,
      sweep_profiles: fn _actor -> [] end,
      sweep_groups: fn _actor -> [] end,
      polling_schedules: fn _actor -> [] end,
      service_checks: fn _actor -> [] end,
      sysmon_profiles: fn _actor -> [] end,
      edge_pipeline_settings: fn _actor -> [] end,
      warehouse_retention_settings: fn _actor -> [] end,
      device_hostname_rdns_settings: fn _actor -> [] end,
      role_profiles: fn _actor -> [] end,
      authorization_settings: fn _actor -> [] end,
      outbound_mail_settings: fn _actor ->
        [
          %{
            id: "50000000-0000-4000-8000-000000000001",
            enabled: true,
            adapter: "smtp",
            from_name: "ServiceRadar",
            from_email: "noreply@example.com",
            relay: "smtp.example.com",
            port: 587,
            hostname: "example.com",
            username: "mailer",
            password: @synthetic_secret_value,
            encrypted_password: @synthetic_ciphertext,
            encrypted_api_key: nil,
            password_secret_id: "00000000-0000-4000-8000-000000000001",
            api_key_secret_id: nil,
            auth: "always",
            tls: "always",
            ssl: false,
            retries: 1,
            provider_options: %{"api_token" => @synthetic_secret_value, "region" => "us-east-1"}
          }
        ]
      end,
      netflow_settings: fn _actor ->
        [
          %{
            id: "60000000-0000-4000-8000-000000000001",
            geoip_enabled: true,
            ipinfo_enabled: false,
            ipinfo_base_url: "https://api.ipinfo.io",
            ipinfo_api_key: @synthetic_secret_value,
            encrypted_ipinfo_api_key: @synthetic_ciphertext,
            threat_intel_enabled: false,
            otx_enabled: false,
            otx_execution_mode: "edge_plugin",
            otx_credential_secret_id: nil,
            otx_base_url: "https://otx.alienvault.com",
            otx_sync_interval_seconds: 3600,
            otx_page_size: 100,
            otx_timeout_ms: 120_000
          }
        ]
      end,
      mapbox_settings: fn _actor ->
        [
          %{
            id: "70000000-0000-4000-8000-000000000001",
            enabled: true,
            style_light: "mapbox://styles/mapbox/light-v11",
            style_dark: "mapbox://styles/mapbox/dark-v11",
            access_token: @synthetic_secret_value,
            encrypted_access_token: @synthetic_ciphertext
          }
        ]
      end
    }
  end
end
