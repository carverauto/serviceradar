defmodule ServiceRadar.Automation.Ansible.SecureExecutionAuthorityContractionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AutomationSecureExecutionCommandAttempt, as: Attempt
  alias ServiceRadar.Automation.Ansible.SecureExecutionAuthorityContraction, as: Contraction
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandContract, as: Contract

  @now ~U[2026-07-13 14:00:00.000000Z]

  defmodule AttemptStore do
    @moduledoc false

    def deny_incomplete(attempt, attrs, _opts) do
      send(Process.get(:contraction_test_pid), {:attempt_denied, attempt, attrs})
      {:ok, %{attempt | state: :failed, processed_at: attrs.processed_at}}
    end

    def create_planned(attrs, _opts) do
      attempt = struct!(Attempt, Map.merge(attrs, %{id: Ash.UUID.generate(), state: :planned}))
      send(Process.get(:contraction_test_pid), {:cancel_planned, attempt})
      {:ok, attempt}
    end
  end

  defmodule LifecycleActions do
    @moduledoc false
    @behaviour ServiceRadar.Automation.Ansible.SecureExecutionLifecycleActions

    @impl true
    def fail_closed(operation, execution, targets, state, diagnostics) do
      send(
        Process.get(:contraction_test_pid),
        {:failed_closed, operation.mutating, execution.id, targets, state, diagnostics}
      )

      {:ok, %{operation: operation, execution: execution, held_targets: targets}}
    end

    @impl true
    def mark_running(_operation, _execution), do: {:error, :not_used}

    @impl true
    def complete_terminal(_operation, _execution, _targets, _state, _evidence),
      do: {:error, :not_used}
  end

  setup do
    Process.put(:contraction_test_pid, self())
    :ok
  end

  test "known-child contraction commits fail-closed holds and a cancel outbox before dispatch" do
    {attempt, resources} = known_child_attempt()
    test_pid = self()

    assert {:ok, :cancellation_planned} =
             Contraction.deny(attempt, resources, :principal_disabled, @now,
               attempt_store: AttemptStore,
               secure_lifecycle_actions: LifecycleActions,
               transaction: fn fun -> {:ok, fun.()} end,
               rollback: fn reason -> throw({:unexpected_rollback, reason}) end,
               dispatcher: fn cancel_attempt ->
                 send(test_pid, {:cancel_dispatched_after_commit, cancel_attempt})
                 {:error, :transport_temporarily_unavailable}
               end
             )

    assert_receive {:attempt_denied, denied, denied_attrs}
    assert denied.id == attempt.id
    assert denied.state == :dispatched
    assert denied_attrs.outcome_code == "current_authority_denied"
    assert denied_attrs.last_error_code == "principal_disabled"

    assert_receive {:failed_closed, true, execution_id, [target], :failed, diagnostics}
    assert execution_id == resources.execution.id
    assert target.id == hd(resources.targets).id
    assert diagnostics["reason"] == "principal_disabled"
    assert diagnostics["cancel_required"] == true

    assert_receive {:cancel_planned, cancel_attempt}
    assert cancel_attempt.stage == :cancel_job
    assert cancel_attempt.purpose == :terminal_cleanup
    assert cancel_attempt.command_type == "awx.cancel_job"
    assert cancel_attempt.expected_job_id == 77
    assert cancel_attempt.dispatch_partition_id == "farm01"
    assert cancel_attempt.state == :planned
    assert DateTime.diff(cancel_attempt.deadline_at, @now, :second) == 60

    assert_receive {:cancel_dispatched_after_commit, dispatched}
    assert dispatched.id == cancel_attempt.id
  end

  defp known_child_attempt do
    operation_id = Ash.UUID.generate()
    execution_id = Ash.UUID.generate()
    controller_id = Ash.UUID.generate()

    execution = %{
      id: execution_id,
      operation_id: operation_id,
      controller_id: controller_id,
      dispatch_id: Ash.UUID.generate(),
      snapshot_digest: String.duplicate("a", 64)
    }

    {:ok, request} = Contract.fetch_job_request(77)

    {:ok, attrs} =
      Contract.build_attempt(
        %{
          operation_id: operation_id,
          execution_id: execution_id,
          controller_id: controller_id,
          dispatch_agent_id: "edge-agent-1",
          dispatch_partition_id: "farm01"
        },
        execution,
        request,
        stage: :fetch_job,
        purpose: :terminal_poll,
        command_type: "awx.fetch_job",
        expected_job_id: 77,
        deadline_at: DateTime.add(@now, 3_600, :second)
      )

    attempt =
      struct!(
        Attempt,
        Map.merge(attrs, %{id: Ash.UUID.generate(), state: :dispatched, inserted_at: @now})
      )

    resources = %{
      operation: %{id: operation_id, mutating: true},
      execution: execution,
      controller: %{id: controller_id, agent_id: "edge-agent-1"},
      targets: [%{id: Ash.UUID.generate(), canonical_device_uid: "sr:device-77"}]
    }

    {attempt, resources}
  end
end
