defmodule ServiceRadar.Automation.Ansible.ExecutionLifecycleTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.ExecutionLifecycle
  alias ServiceRadar.TestSupport.ExecutionLifecycleFakeActions, as: FakeActions

  @controller_id "018f3f56-1111-7222-8333-123456789abc"
  @execution_id "018f3f56-1111-7222-8333-123456789abd"

  setup do
    Process.put(:test_pid, self())
    Process.delete(:execution_lifecycle_bind_result)
    Process.delete(:execution_lifecycle_scope_result)
    :ok
  end

  defp execution(overrides \\ %{}) do
    Map.merge(
      %{
        id: @execution_id,
        controller_id: @controller_id,
        inventory_id: 34,
        job_template_id: 42,
        project_id: 3,
        scm_revision: String.duplicate("a", 40),
        execution_environment_id: 4,
        credential_snapshot: %{
          "credential_ids" => [9, 5],
          "credentials" => [
            %{"id" => 9, "kind" => "cloud"},
            %{"id" => 5, "kind" => "ssh"}
          ]
        },
        check_mode: false,
        host_limit: "farm01-pve01,farm01-node01",
        dispatch_id: "018f3f56-1111-7222-8333-123456789abe",
        snapshot_digest: String.duplicate("b", 64),
        awx_job_id: nil,
        state: :dispatching,
        accepted_job_snapshot: %{},
        metadata: %{"awx_created_by_id" => 11}
      },
      overrides
    )
  end

  defp accepted_job(overrides \\ %{}) do
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
        "credentials" => [%{"id" => 5, "kind" => "ssh"}, %{"id" => 9, "kind" => "cloud"}],
        "launched_by" => %{"id" => 11, "type" => "user"},
        "job_type" => "run",
        "dispatch_markers" => %{
          "serviceradar_dispatch_id" => "018f3f56-1111-7222-8333-123456789abe",
          "serviceradar_snapshot_digest" => String.duplicate("b", 64)
        }
      },
      overrides
    )
  end

  defp targets do
    [
      %{
        id: "target-7",
        execution_id: @execution_id,
        membership_id: "membership-7",
        controller_id: @controller_id,
        inventory_id: 34,
        awx_host_id: 7,
        canonical_device_uid: "sr:device-7",
        host_name: "farm01-pve01"
      },
      %{
        id: "target-8",
        execution_id: @execution_id,
        membership_id: "membership-8",
        controller_id: @controller_id,
        inventory_id: 34,
        awx_host_id: 8,
        canonical_device_uid: "sr:device-8",
        host_name: "farm01-node01"
      }
    ]
  end

  test "binds a controller-scoped job only after every accepted field matches" do
    assert {:ok, bound} =
             ExecutionLifecycle.bind_accepted_job(
               execution(),
               @controller_id,
               accepted_job(),
               actions: FakeActions
             )

    assert bound.awx_job_id == 77
    assert bound.state == :launching

    assert_receive {:bind_accepted_job, _, snapshot}
    assert snapshot["controller_id"] == @controller_id
    assert snapshot["awx_job_id"] == 77
    assert snapshot["credential_ids"] == [5, 9]

    assert snapshot["credentials"] == [
             %{"id" => 5, "kind" => "ssh"},
             %{"id" => 9, "kind" => "cloud"}
           ]

    refute_receive {:reject_scope, _, _, _}
  end

  test "rejects supply-chain, target, mode, and marker drift before job binding" do
    mismatches = [
      {"job_template", 43, :accepted_template_mismatch},
      {"inventory", 35, :accepted_inventory_mismatch},
      {"limit", "all", :accepted_limit_mismatch},
      {"project", 4, :accepted_project_mismatch},
      {"scm_revision", String.duplicate("c", 40), :accepted_scm_revision_mismatch},
      {"execution_environment", 5, :accepted_execution_environment_mismatch},
      {"credentials", [%{"id" => 5, "kind" => "ssh"}], :accepted_credentials_mismatch},
      {"credentials", [%{"id" => 5, "kind" => "vault"}, %{"id" => 9, "kind" => "cloud"}],
       :accepted_credentials_mismatch},
      {"launched_by", %{"id" => 12, "type" => "user"}, :accepted_integration_identity_mismatch},
      {"job_type", "check", :accepted_mode_mismatch},
      {"dispatch_markers", %{}, :accepted_dispatch_id_mismatch}
    ]

    for {field, value, expected_error} <- mismatches do
      assert {:error, ^expected_error} =
               ExecutionLifecycle.bind_accepted_job(
                 execution(),
                 @controller_id,
                 accepted_job(%{field => value}),
                 actions: FakeActions,
                 targets: targets(),
                 mutating?: true
               )

      assert_receive {:reject_scope, _, rejected_targets, diagnostics}
      assert length(rejected_targets) == 2
      assert diagnostics.callback_ready? == false
      assert diagnostics.cancel_required? == true
      refute_receive {:bind_accepted_job, _, _}
    end
  end

  test "does not confuse equal AWX job IDs from different controllers" do
    assert {:error, :authenticated_controller_mismatch} =
             ExecutionLifecycle.bind_accepted_job(
               execution(),
               "018f3f56-1111-7222-8333-999999999999",
               accepted_job(),
               actions: FakeActions
             )

    assert_receive {:reject_scope, _, [], %{callback_ready?: false}}
  end

  test "marks callback ready only after exact post-start host-ID scope is persisted" do
    accepted = execution(%{awx_job_id: 77, state: :launching})

    summaries = [
      %{"job_id" => 77, "host_id" => 8, "host_name" => "farm01-node01"},
      %{"job_id" => 77, "host_id" => 7, "host_name" => "farm01-pve01"}
    ]

    assert {:ok, result} =
             ExecutionLifecycle.verify_host_scope(
               accepted,
               targets(),
               @controller_id,
               77,
               summaries,
               actions: FakeActions
             )

    assert result.callback_ready?
    assert result.execution.state == :scope_verified
    assert result.scope_evidence["expected_host_ids"] == [7, 8]
    assert_receive {:mark_scope_verified, _, _, _}
    refute_receive {:reject_scope, _, _, _}
  end

  test "missing, extra, duplicate, or rebound host evidence remains callback-inactive" do
    accepted = execution(%{awx_job_id: 77, state: :launching})

    bad_summaries = [
      [%{"job_id" => 77, "host_id" => 7, "host_name" => "farm01-pve01"}],
      [
        %{"job_id" => 77, "host_id" => 7, "host_name" => "farm01-pve01"},
        %{"job_id" => 77, "host_id" => 8, "host_name" => "farm01-node01"},
        %{"job_id" => 77, "host_id" => 9, "host_name" => "other"}
      ],
      [
        %{"job_id" => 77, "host_id" => 7, "host_name" => "farm01-pve01"},
        %{"job_id" => 77, "host_id" => 7, "host_name" => "farm01-node01"}
      ],
      [
        %{"job_id" => 78, "host_id" => 7, "host_name" => "farm01-pve01"},
        %{"job_id" => 77, "host_id" => 8, "host_name" => "farm01-node01"}
      ]
    ]

    for summaries <- bad_summaries do
      assert {:error, _reason} =
               ExecutionLifecycle.verify_host_scope(
                 accepted,
                 targets(),
                 @controller_id,
                 77,
                 summaries,
                 actions: FakeActions,
                 mutating?: true
               )

      assert_receive {:reject_scope, _, _, diagnostics}
      assert diagnostics.callback_ready? == false
      refute_receive {:mark_scope_verified, _, _, _}
    end

    assert {:error, :authenticated_job_mismatch} =
             ExecutionLifecycle.verify_host_scope(
               accepted,
               targets(),
               @controller_id,
               78,
               [],
               actions: FakeActions
             )
  end

  test "does not advertise callback readiness when persistence fails" do
    Process.put(:execution_lifecycle_scope_result, {:error, :database_unavailable})
    accepted = execution(%{awx_job_id: 77, state: :launching})

    summaries = [
      %{"job_id" => 77, "host_id" => 7, "host_name" => "farm01-pve01"},
      %{"job_id" => 77, "host_id" => 8, "host_name" => "farm01-node01"}
    ]

    assert {:error, :database_unavailable} =
             ExecutionLifecycle.verify_host_scope(
               accepted,
               targets(),
               @controller_id,
               77,
               summaries,
               actions: FakeActions
             )

    assert_receive {:reject_scope, _, _, %{callback_ready?: false, reason: :database_unavailable}}
  end
end
