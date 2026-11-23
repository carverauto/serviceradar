defmodule ServiceRadar.Jobs.SettingsBackupCollectorAndDestinationTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Jobs.SettingsBackup.Collector
  alias ServiceRadar.Jobs.SettingsBackupDestination

  @roundtrip_bundle_fixture Path.expand(
                              "../../fixtures/settings_backup/terraform_roundtrip_bundle_v1.json",
                              __DIR__
                            )

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

    test "strips hyphenated, synonym, and key-value list secrets while preserving allowed secret ref keys" do
      exported_at = ~U[2026-11-22 12:00:00Z]

      readers =
        :order_a
        |> build_synthetic_readers()
        |> Map.put(:service_checks, fn _actor ->
          [
            %{
              id: "80000000-0000-4000-8000-000000000001",
              name: "HTTPS Check",
              description: "Check with nested auth headers",
              enabled: true,
              check_type: :http,
              target: "https://api.example.com/health",
              port: 443,
              interval_seconds: 60,
              timeout_seconds: 5,
              retries: 1,
              config: %{
                "method" => "GET",
                "api_key" => "inline-service-check-api-key",
                "x_api_key" => "inline-x-api-key",
                "credentials" => "inline-credentials-blob",
                "passphrase" => "inline-passphrase-val",
                "passwd" => "inline-passwd-val",
                "bearer" => "inline-bearer-val",
                "headers" => %{
                  "Authorization" => "Bearer inline-bearer-token",
                  "X-API-Key" => "inline-hyphen-api-key",
                  "Cookie" => "session=inline-cookie-val",
                  "Accept" => "application/json"
                },
                "header_list" => [
                  %{"name" => "Authorization", "value" => "Bearer inline-list-auth"},
                  %{"key" => "X-API-Key", "value" => "inline-list-api-key"},
                  %{"name" => "Accept", "value" => "application/json"}
                ]
              },
              warning_threshold_ms: 500,
              critical_threshold_ms: 1500,
              agent_uid: "agent-1",
              device_uid: "device-1",
              web_property_id: nil,
              metadata: %{
                "authorization" => "Basic inline-basic-auth",
                "api_key_present" => true,
                "api_key_secret_id" => "00000000-0000-4000-8000-000000000099",
                "credential_provider" => "awx",
                "credential_secret_id" => "00000000-0000-4000-8000-000000000098",
                "region" => "us-east-1"
              }
            }
          ]
        end)

      assert {:ok, snap} =
               Collector.collect(exported_at: exported_at, reason: "manual", readers: readers)

      for leaked <- [
            "inline-service-check-api-key",
            "inline-x-api-key",
            "inline-credentials-blob",
            "inline-passphrase-val",
            "inline-passwd-val",
            "inline-bearer-val",
            "inline-bearer-token",
            "inline-hyphen-api-key",
            "inline-cookie-val",
            "inline-list-auth",
            "inline-list-api-key",
            "inline-basic-auth"
          ] do
        refute String.contains?(snap.json, leaked), "expected #{leaked} to be redacted"
      end

      decoded = Jason.decode!(snap.json)
      [check] = decoded["settings"]["service_checks"]

      assert check["config"] == %{
               "headers" => %{"Accept" => "application/json"},
               "header_list" => [
                 %{"name" => "Authorization"},
                 %{"key" => "X-API-Key"},
                 %{"name" => "Accept", "value" => "application/json"}
               ],
               "method" => "GET"
             }

      assert check["metadata"] == %{
               "api_key_present" => true,
               "api_key_secret_id" => "00000000-0000-4000-8000-000000000099",
               "credential_provider" => "awx",
               "credential_secret_id" => "00000000-0000-4000-8000-000000000098",
               "region" => "us-east-1"
             }
    end

    test "strips URL userinfo and sensitive query or fragment parameters across URL fields and nested values" do
      exported_at = ~U[2026-11-22 12:00:00Z]

      readers =
        :order_a
        |> build_synthetic_readers()
        |> Map.put(:ansible_controllers, fn _actor ->
          [
            %{
              id: "20000000-0000-4000-8000-000000000001",
              name: "Primary AWX",
              description: "Synthetic controller",
              base_url:
                "https://awx-bot:inline-awx-pass@awx.example.com:8443/api?token=inline-awx-query-token&org=ops",
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
        end)
        |> Map.put(:ansible_repositories, fn _actor ->
          [
            %{
              id: "30000000-0000-4000-8000-000000000001",
              name: "Playbooks",
              description: nil,
              git_url: "https://bot:inline-git-token@git.example.com/org/playbooks.git",
              git_ref: "main",
              sync_interval_seconds: 600,
              credential_secret_id: nil,
              last_sync_status: :pending,
              last_sync_at: nil,
              metadata: %{}
            },
            %{
              id: "30000000-0000-4000-8000-000000000002",
              name: "Extra Playbooks",
              description: nil,
              git_url: "https://bot:p@ss-inline-at-secret@git.example.com:8443/org/extra.git",
              git_ref: "main",
              sync_interval_seconds: 600,
              credential_secret_id: nil,
              last_sync_status: :pending,
              last_sync_at: nil,
              metadata: %{}
            }
          ]
        end)
        |> Map.put(:service_checks, fn _actor ->
          [
            %{
              id: "80000000-0000-4000-8000-000000000010",
              name: "URL Redaction Check",
              description:
                "Contact mailto:ops@example.com or https://u:inline-desc-pass@status.example.com/ok",
              enabled: true,
              check_type: :http,
              target:
                "https://probe:inline-check-pass@api.example.com/health?mode=deep&api_key=inline-check-api-key&X-API-Key=inline-check-x-api-key#access_token=inline-frag-token&view=summary",
              port: 443,
              interval_seconds: 60,
              timeout_seconds: 5,
              retries: 1,
              config: %{
                "url" =>
                  "https://inline-single-token@hooks.example.com/notify?token=inline-config-token&format=json",
                "encoded_query" =>
                  "https://api.example.com/v1?api%5Fkey=inline-encoded-key&region=us",
                "nested_urls" => [
                  "https://u:inline-list-pass@svc.example.com/a?passwd=inline-list-pw"
                ],
                "redirect" =>
                  "https://api.example.com/go?next=https%3A%2F%2Fu%3Ainline-nested-pass%40dest.example.com%2Fcb%3Ftoken%3Dinline-nested-tok&ok=1"
              },
              warning_threshold_ms: 500,
              critical_threshold_ms: 1500,
              agent_uid: "agent-1",
              device_uid: "device-1",
              web_property_id: nil,
              metadata: %{
                "runbook" => "https://docs.example.com/checks#overview"
              }
            }
          ]
        end)
        |> Map.put(:netflow_settings, fn _actor ->
          [
            %{
              id: "60000000-0000-4000-8000-000000000001",
              geoip_enabled: true,
              ipinfo_enabled: true,
              ipinfo_base_url:
                "https://user:inline-ipinfo-pass@api.ipinfo.io?token=inline-ipinfo-token",
              encrypted_ipinfo_api_key: @synthetic_ciphertext,
              threat_intel_enabled: true,
              otx_enabled: true,
              otx_execution_mode: "edge_plugin",
              otx_credential_secret_id: nil,
              otx_base_url: "https://otx.alienvault.com/api/v1?api_key=inline-otx-key&limit=50",
              otx_sync_interval_seconds: 3600,
              otx_page_size: 100,
              otx_timeout_ms: 120_000
            }
          ]
        end)
        |> Map.put(:mapbox_settings, fn _actor ->
          [
            %{
              id: "70000000-0000-4000-8000-000000000001",
              enabled: true,
              style_light:
                "https://api.mapbox.com/styles/v1/mapbox/light-v11?access_token=inline-mapbox-token&fresh=true",
              style_dark: "mapbox://styles/mapbox/dark-v11",
              encrypted_access_token: @synthetic_ciphertext
            }
          ]
        end)
        |> Map.put(:outbound_mail_settings, fn _actor ->
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
              encrypted_password: @synthetic_ciphertext,
              encrypted_api_key: nil,
              password_secret_id: "00000000-0000-4000-8000-000000000001",
              api_key_secret_id: nil,
              auth: "always",
              tls: "always",
              ssl: false,
              retries: 1,
              provider_options: %{
                "webhook_url" =>
                  "https://mail:inline-mail-pass@hooks.example.com/events?secret=inline-mail-secret"
              }
            }
          ]
        end)

      assert {:ok, snap} =
               Collector.collect(exported_at: exported_at, reason: "manual", readers: readers)

      for leaked <- [
            "inline-awx-pass",
            "inline-awx-query-token",
            "inline-git-token",
            "inline-at-secret",
            "inline-desc-pass",
            "inline-check-pass",
            "inline-check-api-key",
            "inline-check-x-api-key",
            "inline-frag-token",
            "inline-single-token",
            "inline-config-token",
            "inline-encoded-key",
            "inline-list-pass",
            "inline-list-pw",
            "inline-nested-pass",
            "inline-nested-tok",
            "inline-ipinfo-pass",
            "inline-ipinfo-token",
            "inline-otx-key",
            "inline-mapbox-token",
            "inline-mail-pass",
            "inline-mail-secret"
          ] do
        refute String.contains?(snap.json, leaked), "expected #{leaked} to be stripped from json"

        refute String.contains?(Jason.encode!(snap.bundle), leaked),
               "expected #{leaked} to be stripped from bundle"
      end

      decoded = Jason.decode!(snap.json)

      assert [controller] = decoded["terraform_resources"]["serviceradar_ansible_controller"]
      assert controller["base_url"] == "https://awx.example.com:8443/api?org=ops"

      assert [repo1, repo2] = decoded["terraform_resources"]["serviceradar_ansible_repository"]
      assert repo1["git_url"] == "https://git.example.com/org/playbooks.git"
      assert repo2["git_url"] == "https://git.example.com:8443/org/extra.git"

      assert [check] = decoded["settings"]["service_checks"]

      assert check["description"] ==
               "Contact mailto:ops@example.com or https://status.example.com/ok"

      assert check["target"] == "https://api.example.com/health?mode=deep#view=summary"

      assert check["config"] == %{
               "url" => "https://hooks.example.com/notify?format=json",
               "encoded_query" => "https://api.example.com/v1?region=us",
               "nested_urls" => ["https://svc.example.com/a"],
               "redirect" =>
                 "https://api.example.com/go?next=https%3A%2F%2Fdest.example.com%2Fcb&ok=1"
             }

      assert check["metadata"] == %{"runbook" => "https://docs.example.com/checks#overview"}

      assert [netflow] = decoded["settings"]["netflow_settings"]
      assert netflow["ipinfo_base_url"] == "https://api.ipinfo.io"
      assert netflow["otx_base_url"] == "https://otx.alienvault.com/api/v1?limit=50"

      assert [mapbox] = decoded["settings"]["mapbox_settings"]

      assert mapbox["style_light"] ==
               "https://api.mapbox.com/styles/v1/mapbox/light-v11?fresh=true"

      assert mapbox["style_dark"] == "mapbox://styles/mapbox/dark-v11"

      assert [mail] = decoded["settings"]["outbound_mail_settings"]
      assert mail["from_email"] == "noreply@example.com"
      assert mail["provider_options"] == %{"webhook_url" => "https://hooks.example.com/events"}
    end

    test "reproduces the shared Terraform round-trip bundle fixture" do
      expected = @roundtrip_bundle_fixture |> File.read!() |> Jason.decode!()

      readers = build_roundtrip_fixture_readers()

      assert {:ok, snap} =
               Collector.collect(
                 exported_at: ~U[2026-11-22 18:00:00Z],
                 reason: "pre_resize",
                 readers: readers
               )

      assert Jason.decode!(snap.json) == expected
      refute String.contains?(snap.json, @synthetic_secret_value)
      refute String.contains?(snap.json, @synthetic_ciphertext)
      refute String.contains?(snap.json, "values_wo")
    end

    test "propagates read errors instead of returning partial empty collections" do
      readers =
        :order_a
        |> build_synthetic_readers()
        |> Map.put(:service_checks, fn _actor -> {:error, :db_unavailable} end)

      assert {:error, {:collection_failed, ServiceRadar.Monitoring.ServiceCheck, :db_unavailable}} =
               Collector.collect(exported_at: ~U[2026-11-22 12:00:00Z], readers: readers)
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

    test "rejects @reboot cron expressions on create and update" do
      create_cs =
        Ash.Changeset.for_create(SettingsBackupDestination, :create, %{
          enabled: true,
          endpoint: "https://us-east-1.linodeobjects.com",
          bucket: "synthetic-backup-bucket",
          region: "us-east-1",
          schedule_cron: "@reboot",
          access_key_id: "AKIA_SYNTHETIC_KEY",
          secret_access_key: "synthetic-secret-key"
        })

      refute create_cs.valid?
      assert :schedule_cron in Enum.map(create_cs.errors, & &1.field)

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

      update_cs =
        Ash.Changeset.for_update(existing, :update, %{schedule_cron: "@reboot"})

      refute update_cs.valid?
      assert :schedule_cron in Enum.map(update_cs.errors, & &1.field)
    end

    test "run_export_attempt collects canonical bundle and uploads over real CONNECT proxy to TLS origin without leaking secrets" do
      {:ok, _} = Application.ensure_all_started(:ssl)
      certs = generate_certs()
      test_pid = self()
      origin = start_accepting_tls_origin(certs.server_config, test_pid)
      proxy = start_connect_proxy(origin.port)
      prev_http_opts = Application.get_env(:serviceradar_core, :settings_backup_http_opts)

      prev_collector_opts =
        Application.get_env(:serviceradar_core, :settings_backup_collector_opts)

      Application.put_env(:serviceradar_core, :settings_backup_http_opts,
        proxy: %{scheme: :http, host: "127.0.0.1", port: proxy.port},
        cacerts: Keyword.fetch!(certs.client_config, :cacerts)
      )

      Application.put_env(:serviceradar_core, :settings_backup_collector_opts,
        readers: build_roundtrip_fixture_readers()
      )

      on_exit(fn ->
        origin.stop.()
        proxy.stop.()
        restore_core_env(:settings_backup_http_opts, prev_http_opts)
        restore_core_env(:settings_backup_collector_opts, prev_collector_opts)
      end)

      exported_at = ~U[2026-11-22 18:00:00Z]

      dest = %SettingsBackupDestination{
        id: Ecto.UUID.generate(),
        key: "default",
        enabled: true,
        provider: "linode_object_storage",
        endpoint: "https://localhost:#{origin.port}",
        bucket: "synthetic-backup-bucket",
        region: "us-east-1",
        prefix: "tenant-a",
        schedule_cron: "0 */6 * * *",
        access_key_id: "AKIA_SYNTHETIC_KEY",
        secret_access_key: "synthetic-secret-key"
      }

      actor = SystemActor.system(:settings_backup_live_test)

      assert {:ok, result} =
               SettingsBackupDestination.run_export_attempt(
                 dest,
                 exported_at,
                 "pre_resize",
                 actor
               )

      assert result.last_export_status == "succeeded"
      assert result.last_export_error == nil
      assert result.last_exported_at == exported_at
      assert result.last_export_etag == "\"etag-live-1\""
      assert byte_size(result.last_export_sha256) == 64

      sha_prefix = binary_part(result.last_export_sha256, 0, 12)
      expected_key = "tenant-a/settings-export/20261122T180000Z-#{sha_prefix}.json"
      assert result.last_export_object_key == expected_key

      assert_receive {:origin_put, req1}
      assert_receive {:origin_put, req2}
      assert req1.path == "/synthetic-backup-bucket/#{expected_key}"
      assert req2.path == "/synthetic-backup-bucket/tenant-a/settings-export/latest.json"
      assert req1.body == req2.body
      assert req1.headers["x-amz-content-sha256"] == result.last_export_sha256
      assert String.starts_with?(req1.headers["authorization"], "AWS4-HMAC-SHA256 ")

      expected_bundle = @roundtrip_bundle_fixture |> File.read!() |> Jason.decode!()
      assert Jason.decode!(req1.body) == expected_bundle

      for forbidden <- [
            @synthetic_secret_value,
            @synthetic_ciphertext,
            "values_wo",
            "synthetic-secret-key"
          ] do
        refute String.contains?(req1.body, forbidden)
      end

      # Also confirm hyphenated/synonym/header-list secrets are stripped before wire upload.
      redaction_readers =
        :order_a
        |> build_synthetic_readers()
        |> Map.put(:service_checks, fn _actor ->
          [
            %{
              id: "80000000-0000-4000-8000-000000000002",
              name: "Live Redaction Check",
              description: "Check redaction on wire",
              enabled: true,
              check_type: :http,
              target: "https://api.example.com/health",
              port: 443,
              interval_seconds: 60,
              timeout_seconds: 5,
              retries: 1,
              config: %{
                "headers" => %{"X-API-Key" => "wire-hyphen-key", "Cookie" => "wire-cookie-val"},
                "header_list" => [%{"name" => "Authorization", "value" => "Bearer wire-list-val"}],
                "passphrase" => "wire-passphrase-val"
              },
              warning_threshold_ms: 500,
              critical_threshold_ms: 1500,
              agent_uid: "agent-1",
              device_uid: "device-1",
              web_property_id: nil,
              metadata: %{"credentials" => "wire-creds-val", "region" => "us-east-1"}
            }
          ]
        end)

      Application.put_env(:serviceradar_core, :settings_backup_collector_opts,
        readers: redaction_readers
      )

      assert {:ok, _result2} =
               SettingsBackupDestination.run_export_attempt(dest, exported_at, "manual", actor)

      assert_receive {:origin_put, req3}
      assert_receive {:origin_put, _req4}

      for leaked <- [
            "wire-hyphen-key",
            "wire-cookie-val",
            "wire-list-val",
            "wire-passphrase-val",
            "wire-creds-val"
          ] do
        refute String.contains?(req3.body, leaked)
      end
    end

    test "run_export_attempt returns error when S3 upload fails and record_export_failure preserves prior success telemetry" do
      {:ok, _} = Application.ensure_all_started(:ssl)
      certs = generate_certs()
      test_pid = self()
      origin = start_failing_tls_origin(certs.server_config, test_pid)
      prev_http_opts = Application.get_env(:serviceradar_core, :settings_backup_http_opts)

      prev_collector_opts =
        Application.get_env(:serviceradar_core, :settings_backup_collector_opts)

      Application.put_env(:serviceradar_core, :settings_backup_http_opts,
        proxy: nil,
        cacerts: Keyword.fetch!(certs.client_config, :cacerts)
      )

      Application.put_env(:serviceradar_core, :settings_backup_collector_opts,
        readers: build_synthetic_readers(:order_a)
      )

      on_exit(fn ->
        origin.stop.()
        restore_core_env(:settings_backup_http_opts, prev_http_opts)
        restore_core_env(:settings_backup_collector_opts, prev_collector_opts)
      end)

      prior_exported_at = ~U[2026-11-22 10:00:00Z]
      attempt_now = ~U[2026-11-22 12:00:00Z]

      existing = %SettingsBackupDestination{
        id: Ecto.UUID.generate(),
        key: "default",
        enabled: true,
        provider: "linode_object_storage",
        endpoint: "https://localhost:#{origin.port}",
        bucket: "synthetic-backup-bucket",
        region: "us-east-1",
        prefix: "tenant-a",
        schedule_cron: "0 */6 * * *",
        access_key_id: "AKIA_SYNTHETIC_KEY",
        secret_access_key: "synthetic-secret-key",
        last_exported_at: prior_exported_at,
        last_export_status: "succeeded",
        last_export_object_key: "tenant-a/settings-export/20261122T100000Z-abcdef123456.json",
        last_export_etag: "\"etag-prev\"",
        last_export_sha256: String.duplicate("a", 64)
      }

      actor = SystemActor.system(:settings_backup_test)

      assert {:error, "s3_http_status_500"} =
               SettingsBackupDestination.run_export_attempt(
                 existing,
                 attempt_now,
                 "manual",
                 actor
               )

      assert_receive {:origin_put, req1}
      refute String.ends_with?(req1.path, "/latest.json")
      refute_receive {:origin_put, _req2}, 150

      cs =
        Ash.Changeset.for_update(existing, :record_export_failure, %{
          error_message: "s3_http_status_500",
          attempted_at: attempt_now
        })

      assert cs.valid?
      assert Ash.Changeset.get_attribute(cs, :last_export_status) == "failed"
      assert Ash.Changeset.get_attribute(cs, :last_export_error) == "s3_http_status_500"

      assert DateTime.compare(
               Ash.Changeset.get_attribute(cs, :next_run_at),
               DateTime.shift(attempt_now, minute: 5)
             ) == :eq

      assert cs.data.last_exported_at == prior_exported_at

      assert cs.data.last_export_object_key ==
               "tenant-a/settings-export/20261122T100000Z-abcdef123456.json"

      assert cs.data.last_export_etag == "\"etag-prev\""
      assert cs.data.last_export_sha256 == String.duplicate("a", 64)
      refute Map.has_key?(cs.attributes, :last_exported_at)
      refute Map.has_key?(cs.attributes, :last_export_object_key)
      refute Map.has_key?(cs.attributes, :last_export_etag)
      refute Map.has_key?(cs.attributes, :last_export_sha256)
    end

    test "run_export_attempt returns error when collection fails without attempting S3 upload" do
      prev_collector_opts =
        Application.get_env(:serviceradar_core, :settings_backup_collector_opts)

      failing_readers =
        :order_a
        |> build_synthetic_readers()
        |> Map.put(:service_checks, fn _actor -> {:error, :db_unavailable} end)

      Application.put_env(:serviceradar_core, :settings_backup_collector_opts,
        readers: failing_readers
      )

      on_exit(fn ->
        restore_core_env(:settings_backup_collector_opts, prev_collector_opts)
      end)

      existing = %SettingsBackupDestination{
        id: Ecto.UUID.generate(),
        key: "default",
        enabled: true,
        provider: "linode_object_storage",
        endpoint: "https://localhost:9999",
        bucket: "synthetic-backup-bucket",
        region: "us-east-1",
        prefix: "tenant-a",
        schedule_cron: "0 */6 * * *",
        access_key_id: "AKIA_SYNTHETIC_KEY",
        secret_access_key: "synthetic-secret-key"
      }

      actor = SystemActor.system(:settings_backup_test)

      assert {:error, message} =
               SettingsBackupDestination.run_export_attempt(
                 existing,
                 ~U[2026-11-22 12:00:00Z],
                 "manual",
                 actor
               )

      assert String.contains?(
               message,
               "collection_failed:ServiceRadar.Monitoring.ServiceCheck:db_unavailable"
             )
    end

    test "builds priority-0 Oban scheduler and trigger jobs on :maintenance queue" do
      scheduler_job = SettingsBackupDestination.ExportScheduler.new(%{})
      assert scheduler_job.valid?
      assert Ecto.Changeset.get_field(scheduler_job, :priority) == 0
      assert Ecto.Changeset.get_field(scheduler_job, :queue) == "maintenance"

      dest = %SettingsBackupDestination{
        id: "00000000-0000-4000-8000-000000000999",
        key: "default",
        enabled: true
      }

      worker_job =
        AshOban.build_trigger(dest, :export,
          action_arguments: %{"manual" => true, "reason" => "pre_resize"}
        )

      assert worker_job.valid?
      assert Ecto.Changeset.get_field(worker_job, :priority) == 0
      assert Ecto.Changeset.get_field(worker_job, :queue) == "maintenance"
      assert Ecto.Changeset.get_field(worker_job, :max_attempts) == 1

      assert Ecto.Changeset.get_field(worker_job, :worker) ==
               "ServiceRadar.Jobs.SettingsBackupDestination.ExportWorker"

      assert worker_job.changes.args[:primary_key] == %{
               id: "00000000-0000-4000-8000-000000000999"
             }

      assert worker_job.changes.args[:action_arguments] == %{
               "manual" => true,
               "reason" => "pre_resize"
             }
    end
  end

  defp build_roundtrip_fixture_readers do
    %{
      network_credential_secrets: fn _actor ->
        [
          %{
            id: "00000000-0000-4000-8000-000000000101",
            name: "Bundle AWX Secret",
            description: "Synthetic AWX credential",
            provider: "awx",
            credential_kind: :api_token,
            username: nil,
            public_fingerprint: "sha256:synthetic-awx-1",
            managed_by: :operator,
            credential_generation: nil,
            source_type: :internal,
            rotation_state: :active,
            last_rotated_at: ~U[2026-11-20 00:00:00Z],
            secret_payload: @synthetic_secret_value,
            encrypted_secret_payload: @synthetic_ciphertext,
            metadata: %{"auth_method" => "bearer_token", "api_token" => @synthetic_secret_value}
          },
          %{
            id: "00000000-0000-4000-8000-000000000102",
            name: "Bundle Git Secret",
            description: "Synthetic Git credential",
            provider: "git",
            credential_kind: :api_token,
            username: "git-bot",
            public_fingerprint: "sha256:synthetic-git-2",
            managed_by: :operator,
            credential_generation: nil,
            source_type: :internal,
            rotation_state: :active,
            last_rotated_at: nil,
            metadata: %{"auth_method" => "bearer_token"}
          }
        ]
      end,
      network_credential_rules: fn _actor ->
        [
          %{
            id: "00000000-0000-4000-8000-000000000201",
            name: "Bundle AWX Rule",
            description: "Scope AWX credential",
            provider: "awx",
            auth_method: "bearer_token",
            purpose: "automation",
            target_query: "in:devices tags.role:awx",
            scope_type: :agent,
            scope_value: "agent-1",
            secret_id: "00000000-0000-4000-8000-000000000101",
            allowed_ports: [8443, 443],
            tls_policy: :verify,
            ssh_host_key_policy: :known_hosts,
            ca_bundle_pem: nil,
            server_cert_fingerprint: nil,
            priority: 50,
            enabled: true,
            metadata: %{}
          }
        ]
      end,
      ansible_controllers: fn _actor ->
        [
          %{
            id: "00000000-0000-4000-8000-000000000301",
            name: "Bundle AWX Controller",
            description: "Primary controller",
            base_url: "https://awx.example.com",
            agent_id: "agent-1",
            sync_credential_secret_id: "00000000-0000-4000-8000-000000000101",
            execution_credential_secret_id: "00000000-0000-4000-8000-000000000101",
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
            id: "00000000-0000-4000-8000-000000000401",
            name: "Bundle Playbooks Repo",
            description: "Synthetic playbooks",
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
      snmp_profiles: fn _actor -> [] end,
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
      outbound_mail_settings: fn _actor -> [] end,
      netflow_settings: fn _actor -> [] end,
      mapbox_settings: fn _actor -> [] end
    }
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

  defp restore_core_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_core_env(key, val), do: Application.put_env(:serviceradar_core, key, val)

  defp generate_certs do
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}
    alg = [{:digest, :sha256}, {:key, {:namedCurve, :secp256r1}}]

    :public_key.pkix_test_data(%{
      server_chain: %{root: alg, intermediates: [], peer: alg ++ [{:extensions, [san]}]},
      client_chain: %{root: alg, intermediates: [], peer: alg}
    })
  end

  defp start_failing_tls_origin(server_config, test_pid) do
    listen_opts =
      server_config ++
        [
          :binary,
          active: false,
          packet: :raw,
          reuseaddr: true,
          ip: {127, 0, 0, 1},
          versions: [:"tlsv1.3", :"tlsv1.2"]
        ]

    {:ok, listener} = :ssl.listen(0, listen_opts)
    {:ok, {_addr, port}} = :ssl.sockname(listener)
    pid = spawn_link(fn -> origin_accept(listener, test_pid) end)

    %{
      port: port,
      stop: fn ->
        Process.unlink(pid)
        Process.exit(pid, :kill)
        :ssl.close(listener)
      end
    }
  end

  defp origin_accept(listener, test_pid) do
    case :ssl.transport_accept(listener) do
      {:ok, socket} ->
        case :ssl.handshake(socket, 5_000) do
          {:ok, tls_socket} ->
            with {:ok, head} <- read_http_head(tls_socket, "") do
              [request_line | _] = String.split(head, "\r\n")
              [_method, path | _] = String.split(request_line, " ")
              send(test_pid, {:origin_put, %{path: path}})
            end

            :ssl.send(
              tls_socket,
              "HTTP/1.1 500 Internal Server Error\r\ncontent-length: 5\r\nconnection: close\r\n\r\nerror"
            )

            :ssl.close(tls_socket)

          _ ->
            :ok
        end

        origin_accept(listener, test_pid)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        origin_accept(listener, test_pid)
    end
  end

  defp read_http_head(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, _rest] ->
        {:ok, head}

      [_] ->
        case :ssl.recv(socket, 0, 5_000) do
          {:ok, chunk} -> read_http_head(socket, acc <> to_string(chunk))
          err -> err
        end
    end
  end

  defp start_accepting_tls_origin(server_config, test_pid) do
    listen_opts =
      server_config ++
        [
          :binary,
          active: false,
          packet: :raw,
          reuseaddr: true,
          ip: {127, 0, 0, 1},
          versions: [:"tlsv1.3", :"tlsv1.2"]
        ]

    {:ok, listener} = :ssl.listen(0, listen_opts)
    {:ok, {_addr, port}} = :ssl.sockname(listener)
    pid = spawn_link(fn -> accepting_origin_loop(listener, test_pid) end)

    %{
      port: port,
      stop: fn ->
        Process.unlink(pid)
        Process.exit(pid, :kill)
        :ssl.close(listener)
      end
    }
  end

  defp accepting_origin_loop(listener, test_pid) do
    case :ssl.transport_accept(listener) do
      {:ok, socket} ->
        case :ssl.handshake(socket, 5_000) do
          {:ok, tls_socket} ->
            with {:ok, raw} <- read_full_http_request(tls_socket, "") do
              [head, body] = String.split(raw, "\r\n\r\n", parts: 2)
              [request_line | header_lines] = String.split(head, "\r\n")
              [_method, path | _] = String.split(request_line, " ")

              headers =
                Map.new(header_lines, fn line ->
                  [k, v] = String.split(line, ":", parts: 2)
                  {String.downcase(String.trim(k)), String.trim(v)}
                end)

              send(test_pid, {:origin_put, %{path: path, headers: headers, body: body}})
            end

            :ssl.send(
              tls_socket,
              "HTTP/1.1 200 OK\r\netag: \"etag-live-1\"\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
            )

            :ssl.close(tls_socket)

          _ ->
            :ok
        end

        accepting_origin_loop(listener, test_pid)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        accepting_origin_loop(listener, test_pid)
    end
  end

  defp read_full_http_request(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, body] ->
        expected_len = parse_content_length(head)

        if byte_size(body) >= expected_len do
          {:ok, head <> "\r\n\r\n" <> binary_part(body, 0, expected_len)}
        else
          case :ssl.recv(socket, 0, 5_000) do
            {:ok, chunk} -> read_full_http_request(socket, acc <> to_string(chunk))
            err -> err
          end
        end

      [_] ->
        case :ssl.recv(socket, 0, 5_000) do
          {:ok, chunk} -> read_full_http_request(socket, acc <> to_string(chunk))
          err -> err
        end
    end
  end

  defp parse_content_length(head) do
    head
    |> String.split("\r\n")
    |> Enum.find_value(0, fn line ->
      case String.split(line, ":", parts: 2) do
        [name, val] ->
          if String.downcase(String.trim(name)) == "content-length" do
            case Integer.parse(String.trim(val)) do
              {len, ""} -> len
              _ -> 0
            end
          end

        _ ->
          nil
      end
    end)
  end

  defp start_connect_proxy(origin_port) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listener)
    pid = spawn_link(fn -> proxy_accept(listener, origin_port) end)

    %{
      port: port,
      stop: fn ->
        Process.unlink(pid)
        Process.exit(pid, :kill)
        :gen_tcp.close(listener)
      end
    }
  end

  defp proxy_accept(listener, origin_port) do
    case :gen_tcp.accept(listener) do
      {:ok, client} ->
        handler = spawn(fn -> receive do: (:go -> proxy_handle(client, origin_port)) end)
        :ok = :gen_tcp.controlling_process(client, handler)
        send(handler, :go)
        proxy_accept(listener, origin_port)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        proxy_accept(listener, origin_port)
    end
  end

  defp proxy_handle(client, origin_port) do
    with {:ok, request} <- :gen_tcp.recv(client, 0, 5_000),
         true <- String.starts_with?(to_string(request), "CONNECT "),
         {:ok, upstream} <-
           :gen_tcp.connect(
             {127, 0, 0, 1},
             origin_port,
             [:binary, active: false, packet: :raw],
             5_000
           ) do
      :ok = :gen_tcp.send(client, "HTTP/1.0 200 OK\r\n\r\n")
      :ok = :inet.setopts(client, active: true)
      :ok = :inet.setopts(upstream, active: true)
      proxy_relay(client, upstream)
    else
      _ -> :gen_tcp.close(client)
    end
  end

  defp proxy_relay(client, upstream) do
    receive do
      {:tcp, ^client, data} ->
        :gen_tcp.send(upstream, data)
        proxy_relay(client, upstream)

      {:tcp, ^upstream, data} ->
        :gen_tcp.send(client, data)
        proxy_relay(client, upstream)

      {:tcp_closed, _} ->
        :ok

      {:tcp_error, _, _} ->
        :ok
    after
      15_000 -> :ok
    end
  end
end
