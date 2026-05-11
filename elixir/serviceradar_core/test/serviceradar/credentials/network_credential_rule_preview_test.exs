defmodule ServiceRadar.Credentials.NetworkCredentialRulePreviewTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.NetworkCredentialRulePreview

  defmodule FakeResolver do
    @moduledoc false

    def resolve(input_defs, opts) do
      query = input_defs |> hd() |> Map.fetch!(:query)
      rows_by_query = Keyword.fetch!(opts, :rows_by_query)

      {:ok,
       [
         %{
           name: "targets",
           entity: "devices",
           query: query,
           rows: Map.get(rows_by_query, query, [])
         }
       ]}
    end
  end

  test "preview_rule reports scoped agent distribution and sample devices" do
    rule = %{
      id: "rule-a",
      provider: "proxmox",
      purpose: :inventory_enrichment,
      priority: 100,
      target_query: "in:devices metadata.proxmox_candidate:true",
      scope_type: :agent,
      scope_value: "agent-a"
    }

    rows_by_query = %{
      "in:devices metadata.proxmox_candidate:true" => [
        %{"uid" => "device-1", "agent_id" => "agent-a", "ip" => "192.0.2.10"},
        %{"uid" => "device-2", "agent_id" => "agent-a", "ip" => "192.0.2.11"},
        %{"uid" => "device-unmanaged", "ip" => "192.0.2.13"},
        %{"uid" => "device-3", "agent_id" => "agent-b", "ip" => "192.0.2.12"}
      ]
    }

    assert {:ok, preview} =
             NetworkCredentialRulePreview.preview_rule(rule,
               resolver: FakeResolver,
               rows_by_query: rows_by_query,
               sample_limit: 1,
               other_rules: []
             )

    assert preview.rule_id == "rule-a"
    assert preview.matched_devices == 4
    assert preview.scoped_devices == 3
    assert [%{agent_id: "agent-a", device_count: 2}] = preview.agents
    assert [%{"uid" => "device-1"}] = preview.sample_devices
    assert preview.conflicts == []
  end

  test "preview_rule detects equal-priority overlaps in same scope" do
    rule = %{
      "id" => "rule-a",
      "provider" => "proxmox",
      "purpose" => "inventory_enrichment",
      "priority" => 50,
      "target_query" => "in:devices vendor:Proxmox",
      "scope_type" => "agent",
      "scope_value" => "agent-a"
    }

    other_rule = %{
      "id" => "rule-b",
      "provider" => "proxmox",
      "purpose" => "inventory_enrichment",
      "priority" => 50,
      "target_query" => "in:devices metadata.proxmox_candidate:true",
      "scope_type" => "agent",
      "scope_value" => "agent-a"
    }

    rows_by_query = %{
      "in:devices vendor:Proxmox" => [
        %{"uid" => "device-1", "agent_id" => "agent-a"},
        %{"uid" => "device-2", "agent_id" => "agent-a"}
      ],
      "in:devices metadata.proxmox_candidate:true" => [
        %{"uid" => "device-2", "agent_id" => "agent-a"},
        %{"uid" => "device-3", "agent_id" => "agent-a"}
      ]
    }

    assert {:ok, preview} =
             NetworkCredentialRulePreview.preview_rule(rule,
               resolver: FakeResolver,
               rows_by_query: rows_by_query,
               other_rules: [other_rule]
             )

    assert [
             %{
               rule_id: "rule-b",
               priority: 50,
               overlapping_devices: 1,
               sample_device_uids: ["device-2"]
             }
           ] = preview.conflicts
  end
end
