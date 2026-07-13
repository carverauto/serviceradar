defmodule ServiceRadar.Automation.Ansible.CallbackCommandDispatcherTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Automation.Ansible.AutomationCallbackCommandAttempt, as: Attempt
  alias ServiceRadar.Automation.Ansible.CallbackCommandContract
  alias ServiceRadar.Automation.Ansible.CallbackCommandDispatcher

  @now ~U[2026-07-13 12:00:00.000000Z]

  test "a fast terminal result may take the processing lease before dispatch returns" do
    execution = %{
      id: Ash.UUID.generate(),
      dispatch_id: Ash.UUID.generate(),
      snapshot_digest: String.duplicate("a", 64)
    }

    base = %{
      grant_id: Ash.UUID.generate(),
      operation_id: Ash.UUID.generate(),
      execution_id: execution.id,
      controller_id: Ash.UUID.generate(),
      dispatch_agent_id: "agent-farm01"
    }

    {:ok, request} = CallbackCommandContract.fetch_job_request(42)

    {:ok, attrs} =
      CallbackCommandContract.build_attempt(base, execution, request,
        stage: :fetch_job,
        purpose: :accepted_job_proof,
        command_type: "awx.fetch_job",
        expected_job_id: 42,
        deadline_at: DateTime.add(@now, 60, :second),
        next_attempt_at: @now
      )

    attempt = struct!(Attempt, Map.merge(attrs, %{id: Ash.UUID.generate(), state: :planned}))

    assert {:ok, :result_already_processing} =
             CallbackCommandDispatcher.dispatch(attempt,
               now: @now,
               resource_loader: fn ^attempt ->
                 {:ok,
                  %{
                    operation: %{},
                    execution: execution,
                    controller: %{id: base.controller_id},
                    grant: %{}
                  }}
               end,
               claim: fn ^attempt, lease_token, lease_expires_at, now ->
                 assert now == @now

                 {:ok,
                  %{
                    attempt
                    | state: :dispatching,
                      lease_token: lease_token,
                      lease_expires_at: lease_expires_at
                  }}
               end,
               awx_dispatcher: fn claimed, _controller, ^request, context, _opts ->
                 assert claimed.state == :dispatching
                 assert context["verb"] == "awx.fetch_job"
                 {:ok, %{id: claimed.command_id}}
               end,
               mark_dispatched: fn _claimed, _token, now ->
                 assert now == @now
                 {:error, :stale_lease}
               end,
               attempt_fetcher: fn id ->
                 assert id == attempt.id
                 {:ok, %{attempt | state: :processing}}
               end
             )
  end
end
