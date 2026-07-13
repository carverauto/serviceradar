defmodule ServiceRadar.Automation.Ansible.CallbackCommandRecoveryTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AutomationCallbackCommandAttempt, as: Attempt
  alias ServiceRadar.Automation.Ansible.CallbackCommandRecovery
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

  setup do
    Process.put({FakeCoordinator, :test_pid}, self())
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

  defp attempt(stage, command_type, state) do
    %Attempt{
      id: Ash.UUID.generate(),
      grant_id: Ash.UUID.generate(),
      command_id: Ash.UUID.generate(),
      command_type: command_type,
      dispatch_agent_id: "agent-farm01",
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
          agent_id: attempt.dispatch_agent_id
        ],
        overrides
      )
    )
  end
end
