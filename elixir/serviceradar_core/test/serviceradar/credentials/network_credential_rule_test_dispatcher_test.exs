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

  test "dispatch_plan persists redacted payload and transmits runtime token only" do
    plan = %{
      command_type: "proxmox.credential_test",
      agent_id: "agent-a",
      required_capability: "http",
      ttl_seconds: 180,
      context: %{credential_rule_id: "rule-1"},
      payload: %{
        "schema" => "serviceradar.proxmox_credential_test.v1",
        "credential_rule_id" => "rule-1",
        "credential_secret_ref" =>
          "credentialref:network-credential-secret:018f3f56-1111-7222-8333-123456789abc",
        "target" => %{"base_url" => "https://pve.example:8006"},
        "tls" => %{"insecure_skip_verify" => true},
        "timeout_ms" => 30_000
      }
    }

    assert {:ok, result} =
             NetworkCredentialRuleTestDispatcher.dispatch_plan(plan,
               command_bus: FakeCommandBus,
               secret_resolver: fn _ref, _opts -> {:ok, "root@pam!sr=test-secret"} end,
               test_pid: self()
             )

    assert result.command_id == "command-1"
    assert result.payload == plan.payload

    assert_receive {:dispatch, "agent-a", "proxmox.credential_test", persisted, opts}

    assert persisted == plan.payload
    refute inspect(persisted) =~ "test-secret"

    assert opts[:ttl_seconds] == 180
    assert opts[:required_capability] == "http"
    assert opts[:context] == %{credential_rule_id: "rule-1"}

    runtime = opts[:transmit_payload]
    assert runtime["api_token"] == "PVEAPIToken=root@pam!sr=test-secret"
    refute Map.has_key?(runtime, "credential_secret_ref")
  end
end
