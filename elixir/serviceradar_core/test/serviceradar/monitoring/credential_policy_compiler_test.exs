defmodule ServiceRadar.Monitoring.CredentialPolicyCompilerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Monitoring.CredentialPolicyCompiler
  alias ServiceRadar.Monitoring.MonitoredService
  alias ServiceRadar.Monitoring.MonitoringBinding

  test "per-service credential policy overrides binding defaults before grant issue" do
    binding = %MonitoringBinding{
      id: "018f3f56-aaaa-7000-8000-123456789abc",
      descriptor_id: "http.url.availability",
      descriptor_version: "1.0.0",
      credential_policy: %{
        "mode" => "brokered",
        "secret_id" => "018f3f56-1111-7222-8333-123456789abc",
        "allowed_ports" => [443],
        "ttl_seconds" => 300
      }
    }

    service = %MonitoredService{
      id: "018f3f56-bbbb-7000-8000-123456789abc",
      service_key: "https://override.example.test",
      display_name: "Override Service",
      service_kind: :http,
      protocol: "https",
      host: "override.example.test",
      port: 8443,
      path: "/ready",
      metadata: %{
        "credential_policy" => %{
          "secret_id" => "018f3f56-2222-7333-8444-123456789abc",
          "allowed_ports" => [8443],
          "ttl_seconds" => 120
        }
      }
    }

    grant_issuer = fn attrs, _opts ->
      send(self(), {:grant_attrs, attrs})

      {:ok,
       attrs
       |> CredentialBrokerGrant.issue_attrs(~U[2026-05-21 19:40:00Z])
       |> Map.put(:id, "grant-service-override")}
    end

    assert {:ok, snapshot} =
             CredentialPolicyCompiler.compile_for_service(
               binding,
               service,
               "agent-a",
               "check-key-1",
               grant_issuer: grant_issuer
             )

    assert_receive {:grant_attrs, grant_attrs}
    assert grant_attrs.secret_id == "018f3f56-2222-7333-8444-123456789abc"
    assert grant_attrs.allowed_hosts == ["override.example.test"]
    assert grant_attrs.allowed_paths == ["/ready"]
    assert grant_attrs.allowed_ports == [8443]
    assert grant_attrs.ttl_seconds == 120

    refute Map.has_key?(snapshot, "secret_id")
    assert snapshot["allowed_ports"] == [8443]
    assert snapshot["credential_broker_grant_ids"] == ["grant-service-override"]
    assert [grant] = snapshot["credential_brokers"]

    assert grant["credential_secret_ref"] ==
             "credentialref:network-credential-secret:018f3f56-2222-7333-8444-123456789abc"
  end

  test "per-device credential policy fills in when the service has no override" do
    binding = %MonitoringBinding{
      id: "018f3f56-3000-7000-8000-123456789abc",
      descriptor_id: "postgres.availability",
      descriptor_version: "1.0.0",
      credential_policy: %{
        "mode" => "brokered",
        "secret_id" => "018f3f56-3001-7000-8000-123456789abc",
        "ttl_seconds" => 300
      }
    }

    service = %MonitoredService{
      id: "018f3f56-3002-7000-8000-123456789abc",
      service_key: "postgres://device-db.example.test:5432/app",
      display_name: "Device DB",
      service_kind: :database,
      protocol: "postgres",
      host: "device-db.example.test",
      port: 5432,
      device_uid: "sr:device-db-1"
    }

    device_loader = fn "sr:device-db-1", _actor ->
      {:ok,
       %{
         metadata: %{
           "service_monitoring_credential_policy" => %{
             "secret_id" => "018f3f56-3003-7000-8000-123456789abc",
             "ttl_seconds" => 150
           }
         }
       }}
    end

    grant_issuer = fn attrs, _opts ->
      send(self(), {:device_grant_attrs, attrs})

      {:ok,
       attrs
       |> CredentialBrokerGrant.issue_attrs(~U[2026-05-21 19:42:00Z])
       |> Map.put(:id, "grant-device-override")}
    end

    assert {:ok, snapshot} =
             CredentialPolicyCompiler.compile_for_service(
               binding,
               service,
               "agent-device-db",
               "check-key-device-db",
               device_loader: device_loader,
               grant_issuer: grant_issuer
             )

    assert_receive {:device_grant_attrs, grant_attrs}
    assert grant_attrs.secret_id == "018f3f56-3003-7000-8000-123456789abc"
    assert grant_attrs.ttl_seconds == 150
    refute Map.has_key?(snapshot, "secret_id")
  end

  test "credential rule references expand into scoped broker grants without exposing secret ids" do
    binding = %MonitoringBinding{
      id: "018f3f56-cccc-7000-8000-123456789abc",
      descriptor_id: "postgres.availability",
      descriptor_version: "1.0.0",
      credential_policy: %{
        "mode" => "brokered",
        "credential_rule_id" => "018f3f56-dddd-7000-8000-123456789abc",
        "ttl_seconds" => 90
      }
    }

    service = %MonitoredService{
      id: "018f3f56-eeee-7000-8000-123456789abc",
      service_key: "postgres://db.example.test:5432/app",
      display_name: "App DB",
      service_kind: :database,
      protocol: "postgres",
      host: "db.example.test",
      port: 5432
    }

    credential_rule_loader = fn "018f3f56-dddd-7000-8000-123456789abc", _actor ->
      {:ok,
       %NetworkCredentialRule{
         id: "018f3f56-dddd-7000-8000-123456789abc",
         provider: "postgres",
         auth_method: :username_password,
         purpose: :generic,
         secret_id: "018f3f56-ffff-7000-8000-123456789abc",
         allowed_ports: [5432],
         tls_policy: :verify,
         ssh_host_key_policy: :known_hosts
       }}
    end

    grant_issuer = fn attrs, _opts ->
      send(self(), {:rule_grant_attrs, attrs})

      {:ok,
       attrs
       |> CredentialBrokerGrant.issue_attrs(~U[2026-05-21 19:45:00Z])
       |> Map.put(:id, "grant-rule")}
    end

    assert {:ok, snapshot} =
             CredentialPolicyCompiler.compile_for_service(
               binding,
               service,
               "agent-db",
               "check-key-db",
               credential_rule_loader: credential_rule_loader,
               grant_issuer: grant_issuer
             )

    assert_receive {:rule_grant_attrs, grant_attrs}
    assert grant_attrs.secret_id == "018f3f56-ffff-7000-8000-123456789abc"

    assert grant_attrs.secret_ref ==
             "credentialref:network-credential-secret:018f3f56-ffff-7000-8000-123456789abc"

    assert grant_attrs.credential_rule_id == "018f3f56-dddd-7000-8000-123456789abc"
    assert grant_attrs.purpose == "generic"
    assert grant_attrs.allowed_hosts == ["db.example.test"]
    assert grant_attrs.allowed_ports == [5432]
    assert grant_attrs.grant_type == "database_auth"
    assert grant_attrs.inject == %{"type" => "database_auth"}
    assert grant_attrs.ttl_seconds == 90

    refute Map.has_key?(snapshot, "secret_id")
    refute Map.has_key?(snapshot, "secret_ref")
    assert snapshot["credential_rule_id"] == "018f3f56-dddd-7000-8000-123456789abc"
    assert snapshot["provider"] == "postgres"
    assert snapshot["auth_method"] == "username_password"
    assert snapshot["credential_broker_grant_ids"] == ["grant-rule"]
  end

  for {service_kind, protocol, port, grant_type, inject_type} <- [
        {:http, "https", 443, "http_auth", "http_auth"},
        {:database, "postgres", 5432, "database_auth", "database_auth"},
        {:tcp, "tcp", 25, "tcp_auth", "tcp_auth"},
        {:tls, "tls", 993, "tls_auth", "tls_client_auth"}
      ] do
    test "target-bound #{service_kind} grants derive host, port, and injection from the service target" do
      service_kind = unquote(service_kind)
      protocol = unquote(protocol)
      port = unquote(port)
      grant_type = unquote(grant_type)
      inject_type = unquote(inject_type)

      binding = %MonitoringBinding{
        id: "018f3f56-1000-7000-8000-123456789abc",
        descriptor_id: "#{protocol}.availability",
        descriptor_version: "1.0.0",
        credential_policy: %{
          "mode" => "brokered",
          "secret_id" => "018f3f56-1001-7000-8000-123456789abc"
        }
      }

      service = %MonitoredService{
        id: "018f3f56-1002-7000-8000-123456789abc",
        service_key: "#{protocol}://target.example.test:#{port}",
        display_name: "Target",
        service_kind: service_kind,
        protocol: protocol,
        host: "target.example.test",
        port: port
      }

      grant_issuer = fn attrs, _opts ->
        send(self(), {:typed_grant_attrs, attrs})

        {:ok,
         attrs
         |> CredentialBrokerGrant.issue_attrs(~U[2026-05-21 19:50:00Z])
         |> Map.put(:id, "grant-#{service_kind}")}
      end

      assert {:ok, _snapshot} =
               CredentialPolicyCompiler.compile_for_service(
                 binding,
                 service,
                 "agent-#{service_kind}",
                 "check-key-#{service_kind}",
                 grant_issuer: grant_issuer
               )

      assert_receive {:typed_grant_attrs, grant_attrs}
      assert grant_attrs.allowed_hosts == ["target.example.test"]
      assert grant_attrs.allowed_ports == [port]
      assert grant_attrs.grant_type == grant_type
      assert grant_attrs.inject == %{"type" => inject_type}
    end
  end

  test "policy allowlists must match the persisted service target" do
    binding = %MonitoringBinding{
      id: "018f3f56-2000-7000-8000-123456789abc",
      descriptor_id: "http.url.availability",
      descriptor_version: "1.0.0",
      credential_policy: %{
        "mode" => "brokered",
        "secret_id" => "018f3f56-2001-7000-8000-123456789abc",
        "allowed_hosts" => ["evil.example.test"]
      }
    }

    service = %MonitoredService{
      id: "018f3f56-2002-7000-8000-123456789abc",
      service_key: "https://target.example.test/health",
      display_name: "Target",
      service_kind: :http,
      protocol: "https",
      endpoint_url: "https://target.example.test/health",
      host: "target.example.test",
      path: "/health"
    }

    assert {:error,
            {:credential_policy_allowlist_not_target_bound, :allowed_hosts, ["evil.example.test"]}} =
             CredentialPolicyCompiler.compile_for_service(
               binding,
               service,
               "agent-http",
               "check-key-http"
             )
  end
end
