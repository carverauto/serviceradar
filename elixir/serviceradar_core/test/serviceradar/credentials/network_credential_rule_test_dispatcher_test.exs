defmodule ServiceRadar.Credentials.NetworkCredentialRuleTestDispatcherTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.NetworkCredentialRuleTestDispatcher

  defmodule FakeCommandBus do
    @moduledoc false

    def dispatch(agent_id, command_type, persisted_payload, opts) do
      send(opts[:test_pid], {:dispatch, agent_id, command_type, persisted_payload, opts})
      {:ok, "command-1"}
    end
  end

  test "dispatch_plan sends only broker grants and never transmits runtime token" do
    ref = "credentialref:network-credential-secret:018f3f56-1111-7222-8333-123456789abc"

    plan = %{
      command_type: "proxmox.credential_test",
      agent_id: "agent-a",
      required_capability: "http",
      ttl_seconds: 180,
      context: %{credential_rule_id: "rule-1"},
      payload: %{
        "schema" => "serviceradar.proxmox_credential_test.v1",
        "credential_rule_id" => "rule-1",
        "credential_broker" => %{
          "schema" => "serviceradar.edge_credential_broker_grant.v1",
          "credential_rule_id" => "rule-1",
          "credential_secret_ref" => ref,
          "target" => %{"device_uid" => "device-1", "base_url" => "https://pve.example:8006"},
          "allow" => %{"methods" => ["GET"], "paths" => ["/api2/json/nodes"]}
        },
        "debug" => %{"api_token" => "PVEAPIToken=must-not-persist"},
        "target" => %{"base_url" => "https://pve.example:8006"},
        "tls" => %{"insecure_skip_verify" => true},
        "timeout_ms" => 30_000
      }
    }

    assert {:ok, result} =
             NetworkCredentialRuleTestDispatcher.dispatch_plan(plan,
               command_bus: FakeCommandBus,
               test_pid: self()
             )

    assert result.command_id == "command-1"
    assert result.payload["credential_broker"]["credential_secret_ref"] == ref
    assert result.payload["debug"]["api_token"] == "REDACTED"

    assert_receive {:dispatch, "agent-a", "proxmox.credential_test", persisted, opts}

    assert persisted["credential_broker"]["credential_secret_ref"] == ref
    assert persisted["debug"]["api_token"] == "REDACTED"
    refute inspect(persisted) =~ "test-secret"
    refute inspect(persisted) =~ "must-not-persist"

    assert opts[:ttl_seconds] == 180
    assert opts[:required_capability] == "http"
    assert opts[:context] == %{credential_rule_id: "rule-1"}
    refute Keyword.has_key?(opts, :transmit_payload)
  end

  test "dispatch_plan rejects legacy payloads without a broker grant" do
    plan = %{
      command_type: "proxmox.credential_test",
      agent_id: "agent-a",
      required_capability: "http",
      ttl_seconds: 180,
      context: %{credential_rule_id: "rule-1"},
      payload: %{
        "schema" => "serviceradar.proxmox_credential_test.v1",
        "credential_secret_ref" => "credentialref:test-ref"
      }
    }

    assert {:error, :missing_credential_broker_grant} =
             NetworkCredentialRuleTestDispatcher.dispatch_plan(plan,
               command_bus: FakeCommandBus,
               test_pid: self()
             )

    refute_receive {:dispatch, _, _, _, _}
  end
end
