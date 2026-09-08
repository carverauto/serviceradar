defmodule ServiceRadar.Plugins.PolicyAssignmentPlannerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.PluginInputs
  alias ServiceRadar.Plugins.PolicyAssignmentPlanner

  test "plan generates deterministic per-agent assignment specs" do
    policy = %{
      policy_id: "policy-1",
      policy_version: 2,
      plugin_package_id: "pkg-1",
      params_template: %{"collect_events" => true},
      interval_seconds: 30,
      timeout_seconds: 8,
      enabled: true
    }

    resolved_inputs = [
      %{
        name: "devices",
        entity: "devices",
        query: "in:devices vendor:AXIS",
        rows: [
          %{"uid" => "sr:device:1", "agent_id" => "agent-a", "ip" => "10.0.0.1"},
          %{"uid" => "sr:device:2", "agent_id" => "agent-a", "ip" => "10.0.0.2"},
          %{"uid" => "sr:device:3", "agent_id" => "agent-b", "ip" => "10.0.0.3"}
        ]
      },
      %{
        name: "interfaces",
        entity: "interfaces",
        query: "in:interfaces if_name:eth*",
        rows: [
          %{
            "interface_uid" => "if:1",
            "device_id" => "sr:device:1",
            "agent_id" => "agent-a",
            "if_name" => "eth0"
          }
        ]
      }
    ]

    assert {:ok, %{assignments: assignments_a, summary: summary}} =
             PolicyAssignmentPlanner.plan(policy, resolved_inputs,
               chunk_size: 2,
               generated_at: "2026-02-21T23:00:00Z"
             )

    assert summary.matched_rows == 4
    assert summary.agents == 2
    assert summary.generated_assignments == length(assignments_a)

    assert Enum.all?(assignments_a, fn assignment ->
             :ok == PluginInputs.validate(assignment.params)
           end)

    assert {:ok, %{assignments: assignments_b}} =
             PolicyAssignmentPlanner.plan(policy, resolved_inputs,
               chunk_size: 2,
               generated_at: "2026-02-21T23:00:00Z"
             )

    assert Enum.map(assignments_a, & &1.assignment_key) ==
             Enum.map(assignments_b, & &1.assignment_key)
  end

  test "assignment key stays stable when target metadata changes" do
    policy = %{
      policy_id: "camera-policy-1",
      policy_version: 1,
      plugin_package_id: "camera-package-1"
    }

    input = fn hostname, vendor ->
      [
        %{
          name: "targets",
          entity: "devices",
          query: "in:devices ip:192.168.1.62",
          rows: [
            %{
              "uid" => "sr:device:1",
              "agent_id" => "agent-a",
              "ip" => "192.168.1.62",
              "hostname" => hostname,
              "vendor" => vendor
            }
          ]
        }
      ]
    end

    assert {:ok, %{assignments: [before_refresh]}} =
             PolicyAssignmentPlanner.plan(policy, input.("sr-test-01", "Proxmox"),
               generated_at: "2026-07-11T06:00:00Z"
             )

    assert {:ok, %{assignments: [after_refresh]}} =
             PolicyAssignmentPlanner.plan(policy, input.("sr-test-pve04", "Ansible"),
               generated_at: "2026-07-11T06:01:00Z"
             )

    assert before_refresh.assignment_key == after_refresh.assignment_key
    refute before_refresh.params == after_refresh.params
    refute before_refresh.metadata["chunk_hash"] == after_refresh.metadata["chunk_hash"]
  end

  test "plan skips rows without agent ownership and returns policy field errors" do
    invalid_policy = %{
      policy_version: 1,
      plugin_package_id: "pkg-1"
    }

    assert {:error, errors} = PolicyAssignmentPlanner.plan(invalid_policy, [])
    assert Enum.any?(errors, &String.contains?(&1, "policy_id"))

    valid_policy = %{
      policy_id: "policy-1",
      policy_version: 1,
      plugin_package_id: "pkg-1"
    }

    resolved_inputs = [
      %{
        name: "devices",
        entity: "devices",
        query: "in:devices",
        rows: [
          %{"uid" => "sr:device:1", "ip" => "10.0.0.1"},
          %{"uid" => "sr:device:2", "agent_uid" => "agent-a", "ip" => "10.0.0.2"}
        ]
      }
    ]

    assert {:ok, %{summary: summary, assignments: assignments}} =
             PolicyAssignmentPlanner.plan(valid_policy, resolved_inputs,
               generated_at: "2026-02-21T23:10:00Z"
             )

    assert summary.matched_rows == 1
    assert length(assignments) == 1
    assert hd(assignments).agent_uid == "agent-a"
  end

  test "plan can force all resolved rows to a scoped target agent" do
    policy = %{
      policy_id: "policy-1",
      policy_version: 1,
      plugin_package_id: "pkg-1"
    }

    resolved_inputs = [
      %{
        name: "devices",
        entity: "devices",
        query: "in:devices metadata.proxmox_candidate:true",
        rows: [
          %{"uid" => "sr:device:1", "ip" => "10.0.0.1"},
          %{"uid" => "sr:device:2", "agent_id" => "other-agent", "ip" => "10.0.0.2"}
        ]
      }
    ]

    assert {:ok, %{summary: summary, assignments: assignments}} =
             PolicyAssignmentPlanner.plan(policy, resolved_inputs,
               generated_at: "2026-02-21T23:20:00Z",
               target_agent_uid: "scoped-agent"
             )

    assert summary.matched_rows == 2
    assert summary.agents == 1
    assert length(assignments) == 1
    assert hd(assignments).agent_uid == "scoped-agent"

    [%{"items" => items}] = hd(assignments).params["inputs"]
    assert Enum.map(items, & &1["uid"]) == ["sr:device:1", "sr:device:2"]
  end

  test "recovery restriction retains only the target agent's native rows" do
    policy = %{
      policy_id: "policy-1",
      policy_version: 1,
      plugin_package_id: "pkg-1"
    }

    resolved_inputs = [
      %{
        name: "devices",
        entity: "devices",
        query: "in:devices",
        rows: [
          %{"uid" => "sr:device:1", "agent_id" => "recovered-agent", "ip" => "10.0.0.1"},
          %{"uid" => "sr:device:2", "agent_id" => "other-agent", "ip" => "10.0.0.2"},
          %{"uid" => "sr:device:3", "ip" => "10.0.0.3"}
        ]
      }
    ]

    assert {:ok, %{summary: summary, assignments: [assignment]}} =
             PolicyAssignmentPlanner.plan(policy, resolved_inputs,
               generated_at: "2026-07-15T00:00:00Z",
               restrict_agent_uid: "recovered-agent"
             )

    assert summary.matched_rows == 1
    assert summary.agents == 1
    assert assignment.agent_uid == "recovered-agent"

    [%{"items" => items}] = assignment.params["inputs"]
    assert Enum.map(items, & &1["uid"]) == ["sr:device:1"]
  end

  test "single_assignment collapses a chunked target set into one assignment" do
    policy = %{
      policy_id: "network-credential-rule:r1:inventory_sync",
      policy_version: 1,
      plugin_package_id: "pkg-netbox",
      params_template: %{"base_url" => "https://netbox.example.com"}
    }

    rows =
      Enum.map(1..250, fn index ->
        %{
          "uid" => "sr:device:#{String.pad_leading(to_string(index), 4, "0")}",
          "ip" => "10.0.0.1"
        }
      end)

    resolved_inputs = [
      %{name: "targets", entity: "devices", query: "in:devices", rows: rows}
    ]

    opts = [
      chunk_size: 100,
      generated_at: "2026-08-28T00:00:00Z",
      target_agent_uid: "agent-a"
    ]

    # Without the declaration this is the defect: one rule, one agent, one
    # NetBox instance, three assignments -- three complete inventory syncs.
    assert {:ok, %{assignments: chunked}} =
             PolicyAssignmentPlanner.plan(policy, resolved_inputs, opts)

    assert length(chunked) == 3

    assert {:ok, %{assignments: [assignment], summary: summary}} =
             PolicyAssignmentPlanner.plan(
               policy,
               resolved_inputs,
               Keyword.put(opts, :single_assignment, true)
             )

    assert summary.generated_assignments == 1
    assert :ok == PluginInputs.validate(assignment.params)
    assert assignment.metadata["chunk_index"] == 0
    assert assignment.metadata["chunk_total"] == 1

    [%{"items" => items}] = assignment.params["inputs"]
    assert length(items) == 250
  end

  test "single_assignment ignores a chunk_size that would otherwise split the plan" do
    policy = %{
      policy_id: "network-credential-rule:r1:inventory_sync",
      policy_version: 1,
      plugin_package_id: "pkg-netbox"
    }

    rows = Enum.map(1..25, &%{"uid" => "sr:device:#{&1}"})

    resolved_inputs = [
      %{name: "targets", entity: "devices", query: "in:devices", rows: rows}
    ]

    assert {:ok, %{assignments: [_only_one]}} =
             PolicyAssignmentPlanner.plan(policy, resolved_inputs,
               chunk_size: 5,
               single_assignment: true,
               generated_at: "2026-08-28T00:00:00Z",
               target_agent_uid: "agent-a"
             )
  end

  test "single_assignment fails loudly instead of splitting an oversized target set" do
    policy = %{
      policy_id: "network-credential-rule:r1:inventory_sync",
      policy_version: 1,
      plugin_package_id: "pkg-netbox"
    }

    rows = Enum.map(1..600, &%{"uid" => "sr:device:#{&1}"})

    resolved_inputs = [
      %{name: "targets", entity: "devices", query: "in:devices", rows: rows}
    ]

    assert {:error, [message]} =
             PolicyAssignmentPlanner.plan(policy, resolved_inputs,
               single_assignment: true,
               generated_at: "2026-08-28T00:00:00Z",
               target_agent_uid: "agent-a"
             )

    assert message =~ "600 targets"
    assert message =~ "narrow the target query"
  end
end
