defmodule ServiceRadarWebNGWeb.AnsibleLive.AutomationHistoryTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.AnsibleLive.AutomationHistory

  @moduletag :db_free

  test "operation projection drops authority, approval, callback, input, and metadata internals" do
    operation = %{
      id: "operation-1",
      action: "ansible.playbook.run",
      state: :running,
      mutating: false,
      check_mode: false,
      initiator_principal_type: :human,
      initiator_principal_id: "user-42",
      request_source: "ansible_launch_live",
      target_digest: String.duplicate("a", 64),
      diagnostics: %{
        "reason_code" => "scope_mismatch",
        "reason" => "Bearer super-secret-token",
        "source_digest" => String.duplicate("b", 64),
        "credential_snapshot" => %{"password" => "do-not-render"}
      },
      authority_ceiling: %{"permissions" => ["admin"]},
      approval_snapshot: %{"approver" => "private"},
      callback_actions: ["remote_access.ssh_ca.bundle.read"],
      declared_inputs: %{"password" => "private"},
      input_classifications: %{"password" => "secret"},
      run_budget: %{"max" => 100},
      metadata: %{"callback_reference" => "callback-secret"},
      inserted_at: ~U[2026-07-13 00:00:00Z],
      updated_at: ~U[2026-07-13 00:01:00Z]
    }

    projected = AutomationHistory.operation_view(operation)

    assert projected.mutating == false
    assert projected.check_mode == false
    assert Enum.map(projected.diagnostics, & &1.key) == [:reason_code, :source_digest]

    refute Map.has_key?(projected, :authority_ceiling)
    refute Map.has_key?(projected, :approval_snapshot)
    refute Map.has_key?(projected, :callback_actions)
    refute Map.has_key?(projected, :declared_inputs)
    refute Map.has_key?(projected, :input_classifications)
    refute Map.has_key?(projected, :run_budget)
    refute Map.has_key?(projected, :metadata)

    rendered_state = inspect(projected)
    refute rendered_state =~ "super-secret-token"
    refute rendered_state =~ "callback-secret"
    refute rendered_state =~ "do-not-render"
  end

  test "execution projection exposes immutable scope evidence but no credential or callback state" do
    execution = %{
      id: "execution-1",
      operation_id: "operation-1",
      controller_id: "controller-1",
      inventory_id: 34,
      job_template_id: 42,
      project_id: 3,
      scm_revision: String.duplicate("c", 40),
      content_sha256: String.duplicate("d", 64),
      execution_environment_id: 4,
      check_mode: false,
      host_limit: "farm01-web01",
      dispatch_id: "dispatch-1",
      snapshot_digest: String.duplicate("e", 64),
      state: :scope_verified,
      awx_job_id: 77,
      scope_verified_at: ~U[2026-07-13 00:02:00Z],
      diagnostics: %{"expected_host_ids" => [7], "observed_host_ids" => [7]},
      machine_credential_id: 5,
      credential_snapshot: %{"token" => "credential-secret"},
      accepted_job_snapshot: %{"ephemeral_credential_id" => 101},
      callback_reference: "callback-reference-secret",
      metadata: %{"bearer" => "bearer-secret"}
    }

    projected =
      AutomationHistory.execution_view(execution, %{
        id: "controller-1",
        name: "farm01-awx",
        base_url: "https://private.example",
        credential_secret_id: "secret-id"
      })

    assert projected.controller == %{id: "controller-1", name: "farm01-awx"}
    assert projected.awx_job_id == 77
    assert projected.host_limit == "farm01-web01"
    assert projected.scope_verified_at == ~U[2026-07-13 00:02:00Z]

    refute Map.has_key?(projected, :machine_credential_id)
    refute Map.has_key?(projected, :credential_snapshot)
    refute Map.has_key?(projected, :accepted_job_snapshot)
    refute Map.has_key?(projected, :callback_reference)
    refute Map.has_key?(projected, :metadata)

    rendered_state = inspect(projected)
    refute rendered_state =~ "credential-secret"
    refute rendered_state =~ "callback-reference-secret"
    refute rendered_state =~ "private.example"
    refute rendered_state =~ "secret-id"
  end

  test "target diagnostics and hold reasons fail closed on bearer-capable strings" do
    target = %{
      id: "target-1",
      execution_id: "execution-1",
      membership_id: "membership-1",
      canonical_device_uid: "sr:device-1",
      controller_id: "controller-1",
      inventory_id: 34,
      awx_host_id: 7,
      membership_generation: 2,
      host_name: "web01",
      ansible_host: "192.0.2.10",
      status: :scope_mismatch,
      snapshot_digest: String.duplicate("f", 64),
      diagnostics: %{
        stage: :scope_verification,
        reason: "Authorization:Bearer-leaked-value",
        cancel_required?: true,
        expected_host_ids: [7],
        observed_host_ids: [8]
      }
    }

    hold = %{
      id: "hold-1",
      canonical_device_uid: "sr:device-1",
      trigger_execution_target_id: "target-1",
      transaction_id: "transaction-1",
      generation: 2,
      trigger_phase: :unknown,
      reason: "password=should-never-render",
      policy_digest: String.duplicate("1", 64),
      evidence_digest: String.duplicate("2", 64),
      active: true,
      held_at: ~U[2026-07-13 00:03:00Z]
    }

    projected = AutomationHistory.target_view(target, hold)

    assert projected.active_hold.reason == "Details withheld"

    assert Enum.map(projected.diagnostics, & &1.key) == [
             :stage,
             :cancel_required?,
             :expected_host_ids,
             :observed_host_ids
           ]

    refute inspect(projected) =~ "leaked-value"
    refute inspect(projected) =~ "should-never-render"
  end
end
