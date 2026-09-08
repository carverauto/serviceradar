defmodule ServiceRadar.Credentials.CredentialRuleConsumersTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.CredentialRuleConsumers

  @prefix "network-credential-rule:cam-rule"

  defp assignment(attrs) do
    Map.merge(
      %{
        agent_uid: "agent-a",
        plugin_id: "unifi-protect-camera",
        policy_id: @prefix <> ":camera_inventory",
        enabled: true,
        updated_at: ~U[2026-07-01 10:00:00Z]
      },
      attrs
    )
  end

  test "summarizes agents, plugins, purposes, and last materialization" do
    assignments = [
      assignment(%{}),
      assignment(%{
        agent_uid: "agent-b",
        plugin_id: "unifi-protect-camera-stream",
        policy_id: @prefix <> ":camera_stream",
        enabled: false,
        updated_at: ~U[2026-07-02 09:30:00Z]
      })
    ]

    summary = CredentialRuleConsumers.summarize(@prefix, assignments)

    assert summary.total == 2
    assert summary.enabled_count == 1
    assert summary.agent_uids == ["agent-a", "agent-b"]
    assert summary.plugin_ids == ["unifi-protect-camera", "unifi-protect-camera-stream"]
    assert summary.last_materialized_at == ~U[2026-07-02 09:30:00Z]

    assert [first, second] = summary.consumers
    assert first.agent_uid == "agent-a"
    assert first.purpose == "camera_inventory"
    assert first.enabled
    assert second.agent_uid == "agent-b"
    assert second.purpose == "camera_stream"
    refute second.enabled
  end

  test "purposeless policy ids map to the legacy inventory purpose" do
    summary =
      CredentialRuleConsumers.summarize(@prefix, [
        assignment(%{policy_id: @prefix, plugin_id: "proxmox-inventory"})
      ])

    assert [%{purpose: "inventory_enrichment"}] = summary.consumers
  end

  test "empty assignment list yields an explicit empty summary" do
    summary = CredentialRuleConsumers.summarize(@prefix, [])

    assert summary.total == 0
    assert summary.enabled_count == 0
    assert summary.agent_uids == []
    assert summary.plugin_ids == []
    assert summary.last_materialized_at == nil
    assert summary.consumers == []
  end
end
