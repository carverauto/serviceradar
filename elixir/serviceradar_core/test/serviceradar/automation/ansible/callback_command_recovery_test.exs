defmodule ServiceRadar.Automation.Ansible.CallbackCommandRecoveryTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AutomationCallbackCommandAttempt, as: Attempt
  alias ServiceRadar.Automation.Ansible.CallbackCommandRecovery
  alias ServiceRadar.Automation.Ansible.ControllerSecuritySnapshot
  alias ServiceRadar.Edge.AgentCommand

  @now ~U[2026-07-13 12:00:00.000000Z]

  defmodule FakeCoordinator do
    @moduledoc false

    def reconcile_transport_ambiguity(attempt, opts) do
      send(Process.get({__MODULE__, :test_pid}), {:reconcile_transport, attempt, opts})
      {:ok, :reconciled}
    end

    def process_persisted(command_id, agent_id, command_type, opts) do
      send(
        Process.get({__MODULE__, :test_pid}),
        {:process_persisted, command_id, agent_id, command_type, opts}
      )

      {:ok, :processed}
    end
  end

  defmodule FakeLifecycle do
    @moduledoc false

    def revoke(grant_id, reason, _opts) do
      send(Process.get({__MODULE__, :test_pid}), {:grant_revoked, grant_id, reason})
      {:ok, %{id: grant_id, state: :revoked}}
    end
  end

  setup do
    Process.put({FakeCoordinator, :test_pid}, self())
    Process.put({FakeLifecycle, :test_pid}, self())
    :ok
  end

  test "expired persisted create and launch commands reconcile without retransmitting a side effect" do
    for {stage, command_type} <- [
          {:create_credential, "awx.create_callback_credential"},
          {:launch_job, "awx.launch_job"}
        ] do
      attempt = attempt(stage, command_type, :dispatched)

      command =
        command(attempt,
          status: :queued,
          expires_at: DateTime.add(@now, -1, :second)
        )

      result =
        CallbackCommandRecovery.recover_once(
          now: @now,
          attempt_lister: fn now ->
            assert now == @now
            {:ok, [attempt]}
          end,
          activation_cleanup_lister: fn -> {:ok, []} end,
          command_fetcher: fn id ->
            assert id == attempt.command_id
            {:ok, command}
          end,
          dispatcher: fn _ -> flunk("must not retransmit a persisted side-effect command") end,
          coordinator: FakeCoordinator,
          lifecycle_opts: []
        )

      assert result == %{attempts: 1, cleanup_intents: 0}
      assert_receive {:reconcile_transport, ^attempt, _opts}
    end
  end

  test "a terminal command is replayed from its persisted agent and command type" do
    attempt = attempt(:fetch_job, "awx.fetch_job", :dispatched)
    command = command(attempt, status: :completed, expires_at: DateTime.add(@now, 30, :second))

    assert %{attempts: 1, cleanup_intents: 0} =
             CallbackCommandRecovery.recover_once(
               now: @now,
               attempt_lister: fn now ->
                 assert now == @now
                 {:ok, [attempt]}
               end,
               activation_cleanup_lister: fn -> {:ok, []} end,
               command_fetcher: fn _ -> {:ok, command} end,
               coordinator: FakeCoordinator
             )

    assert_receive {:process_persisted, command_id, "agent-farm01", "awx.fetch_job", _opts}
    assert command_id == attempt.command_id
  end

  test "a terminal command from the same agent in another partition is not replayed" do
    attempt = attempt(:fetch_job, "awx.fetch_job", :dispatched)

    command =
      attempt
      |> command(status: :completed, expires_at: DateTime.add(@now, 30, :second))
      |> Map.put(:partition_id, "tonka01")

    assert %{attempts: 1, cleanup_intents: 0} =
             CallbackCommandRecovery.recover_once(
               now: @now,
               attempt_lister: fn _now -> {:ok, [attempt]} end,
               activation_cleanup_lister: fn -> {:ok, []} end,
               command_fetcher: fn _ -> {:ok, command} end,
               coordinator: FakeCoordinator
             )

    refute_receive {:process_persisted, _, _, _, _}
    refute_receive {:reconcile_transport, _, _}
  end

  test "a crash after activation is recovered by the durable cleanup intent" do
    attempt =
      :fetch_host_summaries
      |> attempt("awx.fetch_job_host_summaries", :succeeded)
      |> Map.put(:outcome_code, "scope_verified_and_activated")

    assert %{attempts: 0, cleanup_intents: 1} =
             CallbackCommandRecovery.recover_once(
               now: @now,
               attempt_lister: fn now ->
                 assert now == @now
                 {:ok, []}
               end,
               activation_cleanup_lister: fn -> {:ok, [attempt]} end,
               grant_fetcher: fn grant_id ->
                 assert grant_id == attempt.grant_id
                 {:ok, %{id: grant_id, credential_cleanup_state: :pending}}
               end,
               delete_activated: fn grant_id -> send(self(), {:delete_activated, grant_id}) end
             )

    assert_receive {:delete_activated, grant_id}
    assert grant_id == attempt.grant_id
  end

  test "confirmed activation cleanup is monotonic and is not dispatched again" do
    attempt =
      :fetch_host_summaries
      |> attempt("awx.fetch_job_host_summaries", :succeeded)
      |> Map.put(:outcome_code, "scope_verified_and_activated")

    assert %{attempts: 0, cleanup_intents: 1} =
             CallbackCommandRecovery.recover_once(
               now: @now,
               attempt_lister: fn now ->
                 assert now == @now
                 {:ok, []}
               end,
               activation_cleanup_lister: fn -> {:ok, [attempt]} end,
               grant_fetcher: fn _ ->
                 {:ok, %{id: attempt.grant_id, credential_cleanup_state: :deleted}}
               end,
               delete_activated: fn _ -> flunk("must not repeat confirmed deletion") end
             )
  end

  test "a stale deleting cleanup is retried with an explicit idempotent-delete signal" do
    attempt =
      :fetch_host_summaries
      |> attempt("awx.fetch_job_host_summaries", :succeeded)
      |> Map.put(:outcome_code, "scope_verified_and_activated")

    assert %{attempts: 0, cleanup_intents: 1} =
             CallbackCommandRecovery.recover_once(
               now: @now,
               attempt_lister: fn _now -> {:ok, []} end,
               activation_cleanup_lister: fn retry_before ->
                 assert retry_before == ~U[2026-07-13 11:58:00.000000Z]
                 {:ok, [attempt]}
               end,
               grant_fetcher: fn _ ->
                 {:ok,
                  %{
                    id: attempt.grant_id,
                    credential_cleanup_state: :deleting,
                    credential_cleanup_attempted_at: ~U[2026-07-13 11:57:59.000000Z]
                  }}
               end,
               delete_activated: fn grant_id, retry_deleting? ->
                 send(self(), {:delete_activated_retry, grant_id, retry_deleting?})
               end
             )

    assert_receive {:delete_activated_retry, grant_id, true}
    assert grant_id == attempt.grant_id
  end

  test "an elapsed active watchdog revokes authority and holds before closing its attempt" do
    attempt =
      :fetch_job
      |> attempt("awx.fetch_job", :waiting)
      |> Map.put(:purpose, :terminal_poll)
      |> Map.put(:deadline_at, DateTime.add(@now, -1, :second))

    test_pid = self()

    assert %{attempts: 1, cleanup_intents: 0} =
             CallbackCommandRecovery.recover_once(
               now: @now,
               attempt_lister: fn _now -> {:ok, [attempt]} end,
               activation_cleanup_lister: fn -> {:ok, []} end,
               lifecycle: FakeLifecycle,
               lifecycle_opts: [],
               postactivation_failure_handler: fn failed_attempt, reason ->
                 send(test_pid, {:postactivation_failed, failed_attempt.id, reason})
                 {:ok, :held}
               end,
               deadline_marker: fn failed_attempt, attrs ->
                 send(test_pid, {:deadline_marked, failed_attempt.id, attrs})
                 {:ok, failed_attempt}
               end,
               command_fetcher: fn command_id ->
                 send(test_pid, {:deadline_command_checked, command_id})
                 {:ok, nil}
               end
             )

    assert_receive {:deadline_command_checked, command_id}
    assert command_id == attempt.command_id

    assert_receive {:grant_revoked, grant_id, :callback_command_deadline_elapsed}
    assert grant_id == attempt.grant_id

    assert_receive {:postactivation_failed, attempt_id, :callback_command_deadline_elapsed}
    assert attempt_id == attempt.id

    assert_receive {:deadline_marked, ^attempt_id, attrs}
    assert attrs.last_error_code == "callback_command_deadline_elapsed"
  end

  test "terminal evidence is processed cleanup-only even when the attempt deadline elapsed" do
    attempt =
      :launch_job
      |> attempt("awx.launch_job", :dispatched)
      |> Map.put(:deadline_at, DateTime.add(@now, -1, :second))

    command = command(attempt, status: :completed, expires_at: DateTime.add(@now, -1, :second))

    assert %{attempts: 1, cleanup_intents: 0} =
             CallbackCommandRecovery.recover_once(
               now: @now,
               attempt_lister: fn _now -> {:ok, [attempt]} end,
               activation_cleanup_lister: fn -> {:ok, []} end,
               command_fetcher: fn _ -> {:ok, command} end,
               coordinator: FakeCoordinator,
               lifecycle: FakeLifecycle,
               lifecycle_opts: [],
               deadline_marker: fn _, _ ->
                 flunk("terminal evidence must be consumed before generic deadline expiry")
               end
             )

    assert_receive {:process_persisted, command_id, "agent-farm01", "awx.launch_job", opts}
    assert command_id == attempt.command_id
    assert opts[:cleanup_only] == true
    refute_receive {:grant_revoked, _, :callback_command_deadline_elapsed}
  end

  test "recovery reauthorizes an in-flight pending scope command before waiting" do
    attempt =
      :fetch_job
      |> attempt("awx.fetch_job", :dispatched)
      |> Map.put(:purpose, :scope_poll)
      |> Map.put(:expected_job_id, 42)

    command =
      command(attempt,
        status: :running,
        expires_at: DateTime.add(@now, 30, :second)
      )

    controller = %{
      id: attempt.controller_id,
      name: "farm01-awx",
      base_url: "https://awx.example.test:8443",
      agent_id: attempt.dispatch_agent_id,
      enabled: true,
      sync_credential_secret_id: Ash.UUID.generate(),
      execution_credential_secret_id: Ash.UUID.generate(),
      callback_credential_secret_id: Ash.UUID.generate(),
      metadata: %{}
    }

    {:ok, controller_snapshot} = ControllerSecuritySnapshot.capture(controller)

    resources = %{
      operation: %{id: attempt.operation_id, mutating: true},
      execution: %{
        id: attempt.execution_id,
        metadata: %{
          "dispatch_partition_id" => attempt.dispatch_partition_id,
          "controller_security_snapshot" => controller_snapshot
        }
      },
      controller: controller,
      grant: %{
        id: attempt.grant_id,
        dispatch_agent_id: attempt.dispatch_agent_id,
        dispatch_partition_id: attempt.dispatch_partition_id
      },
      targets: [%{id: Ash.UUID.generate()}]
    }

    test_pid = self()

    assert %{attempts: 1, cleanup_intents: 0} =
             CallbackCommandRecovery.recover_once(
               now: @now,
               attempt_lister: fn _now -> {:ok, [attempt]} end,
               activation_cleanup_lister: fn -> {:ok, []} end,
               command_fetcher: fn _ -> {:ok, command} end,
               continuation_authorizer: fn recovered ->
                 ServiceRadar.Automation.Ansible.CallbackCommandDispatcher.reauthorize_continuation(
                   recovered,
                   resource_loader: fn ^recovered -> {:ok, resources} end,
                   callback_authorizer: fn mode, _grant, _opts ->
                     assert mode == :pending_job
                     send(test_pid, :pending_reauthorized)
                     {:error, :principal_disabled}
                   end,
                   active_contraction_handler: fn _resources, reason ->
                     send(test_pid, {:pending_contracted, reason})
                     {:ok, :held_and_cancel_requested}
                   end,
                   authority_denial_marker: fn denied, reason, _now, _opts ->
                     send(test_pid, {:pending_attempt_denied, denied.id, reason})
                     {:ok, denied}
                   end
                 )
               end,
               coordinator: FakeCoordinator
             )

    assert_receive :pending_reauthorized
    assert_receive {:pending_contracted, :principal_disabled}
    assert_receive {:pending_attempt_denied, attempt_id, :principal_disabled}
    assert attempt_id == attempt.id
    refute_receive {:process_persisted, _, _, _, _}
  end

  defp attempt(stage, command_type, state) do
    %Attempt{
      id: Ash.UUID.generate(),
      grant_id: Ash.UUID.generate(),
      operation_id: Ash.UUID.generate(),
      execution_id: Ash.UUID.generate(),
      controller_id: Ash.UUID.generate(),
      command_id: Ash.UUID.generate(),
      command_type: command_type,
      dispatch_agent_id: "agent-farm01",
      dispatch_partition_id: "farm01",
      stage: stage,
      state: state,
      deadline_at: DateTime.add(@now, 60, :second)
    }
  end

  defp command(attempt, overrides) do
    struct!(
      AgentCommand,
      Keyword.merge(
        [
          id: attempt.command_id,
          command_type: attempt.command_type,
          agent_id: attempt.dispatch_agent_id,
          partition_id: attempt.dispatch_partition_id
        ],
        overrides
      )
    )
  end
end
