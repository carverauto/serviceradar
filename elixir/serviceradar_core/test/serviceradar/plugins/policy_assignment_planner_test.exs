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
end
