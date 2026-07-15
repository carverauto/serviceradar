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
end
