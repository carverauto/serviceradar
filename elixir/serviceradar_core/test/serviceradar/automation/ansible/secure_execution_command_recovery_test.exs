defmodule ServiceRadar.Automation.Ansible.SecureExecutionCommandRecoveryTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AutomationSecureExecutionCommandAttempt, as: Attempt
  alias ServiceRadar.Automation.Ansible.SecureExecutionCommandRecovery, as: Recovery
  alias ServiceRadar.Edge.AgentCommand

  defmodule FakeCoordinator do
    @moduledoc false

    def process_persisted(command_id, agent_id, command_type, _opts) do
      send(Process.get(:test_pid), {:process_persisted, command_id, agent_id, command_type})
      {:ok, :processed}
    end

    def reconcile_transport_ambiguity(attempt, _opts) do
      send(Process.get(:test_pid), {:reconcile_transport, attempt.command_id})
      {:ok, :reconciling}
    end

    def expire_attempt(attempt, _opts) do
      send(Process.get(:test_pid), {:expire_attempt, attempt.command_id})
      {:ok, :expired}
    end
  end

  setup do
    Process.put(:test_pid, self())
    :ok
  end

  test "missed terminal notifications replay the persisted command result even after deadline" do
    now = now()
    attempt = attempt(:fetch_job, DateTime.add(now, -1, :second))
    command = command(attempt, :completed, DateTime.add(now, -30, :second))

    assert %{attempts: 1} =
             recover(attempt, command,
               now: now,
               dispatcher: fn _ -> send(self(), :unsafe_dispatch) end
             )

    assert_receive {:process_persisted, command_id, "edge-agent-1", "awx.fetch_job"}
    assert command_id == attempt.command_id
    refute_receive :unsafe_dispatch
    refute_receive {:expire_attempt, _}
  end

  test "an expired persisted launch is reconciled and never blindly relaunched" do
    now = now()
    attempt = attempt(:launch_job, DateTime.add(now, -1, :second))
    command = command(attempt, :sent, DateTime.add(now, -10, :second))
    test_pid = self()

    assert %{attempts: 1} =
             recover(attempt, command,
               now: now,
               dispatcher: fn _ ->
                 send(test_pid, :unsafe_relaunch)
                 {:error, :unsafe}
               end
             )

    assert_receive {:reconcile_transport, command_id}
    assert command_id == attempt.command_id
    refute_receive :unsafe_relaunch
  end

  test "a missing preallocated command may dispatch only its durable planned attempt" do
    attempt = attempt(:launch_job, DateTime.add(now(), 60, :second))
    test_pid = self()

    assert %{attempts: 1} =
             recover(attempt, nil,
               dispatcher: fn recovered ->
                 send(test_pid, {:dispatch, recovered.command_id})
                 {:ok, :dispatched}
               end
             )

    assert_receive {:dispatch, command_id}
    assert command_id == attempt.command_id
    refute_receive {:reconcile_transport, _}
  end

  test "a non-launch command whose bounded deadline elapsed fails through expiration" do
    now = now()
    attempt = attempt(:fetch_job, DateTime.add(now, -1, :second))
    command = command(attempt, :running, DateTime.add(now, 30, :second))

    assert %{attempts: 1} = recover(attempt, command, now: now)
    assert_receive {:expire_attempt, command_id}
    assert command_id == attempt.command_id
    refute_receive {:reconcile_transport, _}
  end

  defp recover(attempt, command, opts) do
    Recovery.recover_once(
      Keyword.merge(
        [
          attempt_lister: fn _now -> {:ok, [attempt]} end,
          command_fetcher: fn _command_id -> {:ok, command} end,
          coordinator: FakeCoordinator
        ],
        opts
      )
    )
  end

  defp command(attempt, status, expires_at) do
    struct!(AgentCommand,
      id: attempt.command_id,
      command_type: attempt.command_type,
      agent_id: attempt.dispatch_agent_id,
      status: status,
      expires_at: expires_at
    )
  end

  defp attempt(stage, deadline_at) do
    {command_type, purpose, expected_job_id} =
      case stage do
        :launch_job -> {"awx.launch_job", :accepted_job_proof, nil}
        :fetch_job -> {"awx.fetch_job", :terminal_poll, 77}
      end

    struct!(Attempt,
      id: Ash.UUID.generate(),
      operation_id: Ash.UUID.generate(),
      execution_id: Ash.UUID.generate(),
      controller_id: Ash.UUID.generate(),
      dispatch_agent_id: "edge-agent-1",
      stage: stage,
      purpose: purpose,
      attempt: 1,
      command_id: Ash.UUID.generate(),
      command_type: command_type,
      request_schema_version: "serviceradar.automation_execution_command/v1",
      request_digest: String.duplicate("a", 64),
      context_digest: String.duplicate("b", 64),
      expected_job_id: expected_job_id,
      candidate_job_ids: [],
      state: :planned,
      deadline_at: deadline_at,
      inserted_at: now()
    )
  end

  defp now, do: DateTime.truncate(DateTime.utc_now(), :microsecond)
end
