defmodule ServiceRadar.Automation.Ansible.SecureExecutionLifecycleTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.ExecutionLifecycle
  alias ServiceRadar.Automation.Ansible.SecureExecutionLifecycle

  @controller_id "018f3f56-1111-7222-8333-123456789abc"
  @execution_id "018f3f56-1111-7222-8333-123456789abd"
  @operation_id "018f3f56-1111-7222-8333-123456789abe"

  defmodule FakeActions do
    @moduledoc false

    def mark_running(operation, execution) do
      send(Process.get(:test_pid), {:mark_running, operation, execution})
      {:ok, %{operation: operation, execution: execution}}
    end

    def complete_terminal(operation, execution, outcomes, state, evidence) do
      send(Process.get(:test_pid), {:complete_terminal, outcomes, state, evidence})
      {:ok, %{operation: operation, execution: execution, target_outcomes: outcomes}}
    end

    def fail_closed(operation, execution, targets, state, diagnostics) do
      send(Process.get(:test_pid), {:fail_closed, state, diagnostics})
      {:ok, %{operation: operation, execution: execution, targets: targets}}
    end
  end

  setup do
    Process.put(:test_pid, self())
    :ok
  end

  test "terminal success preserves changed=0 as an exact successful target outcome" do
    {operation, execution, targets, job} = running_bundle("successful")

    summaries = [summary(7, "farm01-pve01"), summary(8, "farm01-node01")]

    assert {:ok, _result} =
             SecureExecutionLifecycle.complete_terminal(
               operation,
               execution,
               targets,
               @controller_id,
               job,
               summaries,
               actions: FakeActions
             )

    assert_receive {:complete_terminal, outcomes, :succeeded, evidence}

    assert Enum.map(outcomes, fn {_target, status, diagnostics} ->
             {status, diagnostics["changed"]}
           end) ==
             [{:ok, 0}, {:ok, 0}]

    assert evidence["awx_status"] == "successful"
  end

  test "terminal failure and cancellation derive per-target outcomes from exact summaries" do
    {operation, execution, targets, failed_job} = running_bundle("failed")

    failed =
      summary(7, "farm01-pve01", %{"failures" => 1, "failed" => true, "processed" => 1})

    assert {:ok, _result} =
             SecureExecutionLifecycle.complete_terminal(
               operation,
               execution,
               targets,
               @controller_id,
               failed_job,
               [failed, summary(8, "farm01-node01")],
               actions: FakeActions
             )

    assert_receive {:complete_terminal, outcomes, :failed, _evidence}
    assert Enum.map(outcomes, fn {_target, status, _diagnostics} -> status end) == [:failed, :ok]

    {operation, execution, targets, canceled_job} = running_bundle("canceled")

    assert {:ok, _result} =
             SecureExecutionLifecycle.complete_terminal(
               operation,
               execution,
               targets,
               @controller_id,
               canceled_job,
               [summary(7, "farm01-pve01"), summary(8, "farm01-node01")],
               actions: FakeActions
             )

    assert_receive {:complete_terminal, outcomes, :canceled, _evidence}
    assert Enum.all?(outcomes, fn {_target, status, _diagnostics} -> status == :canceled end)
  end

  test "incomplete terminal host summaries never complete an execution" do
    {operation, execution, targets, job} = running_bundle("successful")

    assert {:error, :terminal_host_summaries_incomplete} =
             SecureExecutionLifecycle.complete_terminal(
               operation,
               execution,
               targets,
               @controller_id,
               job,
               [summary(7, "farm01-pve01")],
               actions: FakeActions
             )

    refute_receive {:complete_terminal, _, _, _}
  end

  test "accepted-job provenance drift is rejected at terminal polling" do
    {_operation, execution, _targets, job} = running_bundle("successful")
    drifted = put_in(job, ["credentials"], [%{"id" => 999, "kind" => "ssh"}])

    assert {:error, :accepted_credentials_mismatch} =
             SecureExecutionLifecycle.validate_bound_job(execution, @controller_id, drifted)
  end

  test "fail-closed diagnostics classify arbitrary errors without retaining secrets" do
    {operation, execution, targets, _job} = running_bundle("running")
    secret = "super-secret-password-value"

    assert {:ok, _result} =
             SecureExecutionLifecycle.fail_closed(
               operation,
               execution,
               targets,
               :failed,
               %{password: secret},
               actions: FakeActions
             )

    assert_receive {:fail_closed, :failed, diagnostics}
    assert diagnostics["reason"] == "internal_error"
    assert diagnostics["evidence_digest"] =~ ~r/^[0-9a-f]{64}$/
    refute inspect(diagnostics) =~ secret
  end

  defp running_bundle(status) do
    base_execution = execution()
    job = accepted_job(%{"status" => status})

    {:ok, accepted} =
      ExecutionLifecycle.accepted_job_snapshot(base_execution, @controller_id, job)

    execution =
      Map.merge(base_execution, %{
        state: :running,
        awx_job_id: 77,
        accepted_job_snapshot: Map.put(accepted, "scope_verification", %{"schema" => "scope.v1"})
      })

    operation = %{
      id: @operation_id,
      state: :running,
      mutating: true
    }

    {operation, execution, targets(), job}
  end

  defp execution do
    %{
      id: @execution_id,
      operation_id: @operation_id,
      controller_id: @controller_id,
      inventory_id: 34,
      job_template_id: 42,
      project_id: 3,
      scm_revision: String.duplicate("a", 40),
      execution_environment_id: 4,
      credential_snapshot: %{
        "credential_ids" => [5, 9],
        "credentials" => [
          %{"id" => 5, "kind" => "ssh"},
          %{"id" => 9, "kind" => "cloud"}
        ]
      },
      check_mode: false,
      host_limit: "farm01-pve01,farm01-node01",
      dispatch_id: "018f3f56-1111-7222-8333-123456789abf",
      snapshot_digest: String.duplicate("b", 64),
      awx_job_id: nil,
      state: :dispatching,
      accepted_job_snapshot: %{},
      metadata: %{"awx_created_by_id" => 11}
    }
  end

  defp accepted_job(overrides) do
    Map.merge(
      %{
        "controller_id" => @controller_id,
        "job_id" => 77,
        "job_template" => 42,
        "inventory" => 34,
        "limit" => "farm01-pve01,farm01-node01",
        "project" => 3,
        "scm_revision" => String.duplicate("a", 40),
        "execution_environment" => 4,
        "credentials" => [
          %{"id" => 5, "kind" => "ssh"},
          %{"id" => 9, "kind" => "cloud"}
        ],
        "launched_by" => %{"id" => 11, "type" => "user"},
        "job_type" => "run",
        "job_slice_count" => 1,
        "job_slice_number" => 0,
        "dispatch_markers" => %{
          "serviceradar_dispatch_id" => "018f3f56-1111-7222-8333-123456789abf",
          "serviceradar_snapshot_digest" => String.duplicate("b", 64)
        }
      },
      overrides
    )
  end

  defp targets do
    [
      target(7, "farm01-pve01", "target-7"),
      target(8, "farm01-node01", "target-8")
    ]
  end

  defp target(host_id, host_name, id) do
    %{
      id: id,
      execution_id: @execution_id,
      membership_id: "membership-#{host_id}",
      controller_id: @controller_id,
      inventory_id: 34,
      awx_host_id: host_id,
      canonical_device_uid: "sr:device-#{host_id}",
      host_name: host_name
    }
  end

  defp summary(host_id, host_name, overrides \\ %{}) do
    Map.merge(
      %{
        "job_id" => 77,
        "host_id" => host_id,
        "host_name" => host_name,
        "changed" => 0,
        "dark" => 0,
        "failures" => 0,
        "ok" => 1,
        "processed" => 1,
        "skipped" => 0,
        "failed" => false,
        "ignored" => 0,
        "rescued" => 0
      },
      overrides
    )
  end
end
