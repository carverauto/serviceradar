defmodule ServiceRadarWebNGWeb.DiagnosticsLive.MtrDataTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentCommand
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrData

  setup do
    user = AccountsFixtures.user_fixture(%{role: :admin})

    %{
      actor: SystemActor.system(:mtr_data_test),
      scope: Scope.for_user(user)
    }
  end

  test "list_pending_jobs excludes expired active mtr commands", %{actor: actor, scope: scope} do
    stale =
      create_mtr_command(actor, "agent-stale", "192.0.2.10",
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second),
        status: :acknowledged
      )

    fresh =
      create_mtr_command(actor, "agent-fresh", "192.0.2.20",
        expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
        status: :sent
      )

    assert {:ok, jobs} = MtrData.list_pending_jobs(scope)

    job_ids = MapSet.new(Enum.map(jobs, & &1.id))

    assert MapSet.member?(job_ids, fresh.id)
    refute MapSet.member?(job_ids, stale.id)
  end

  defp create_mtr_command(actor, agent_id, target, opts) do
    expires_at = Keyword.fetch!(opts, :expires_at)
    status = Keyword.get(opts, :status, :queued)

    {:ok, command} =
      AgentCommand.create_command(
        %{
          command_type: "mtr.run",
          agent_id: agent_id,
          partition_id: "default",
          payload: %{"target" => target},
          ttl_seconds: 60,
          expires_at: expires_at
        },
        actor: actor
      )

    case status do
      :queued ->
        command

      :sent ->
        {:ok, command} = AgentCommand.mark_sent(command, [partition_id: "default"], actor: actor)
        command

      :acknowledged ->
        {:ok, command} = AgentCommand.mark_sent(command, [partition_id: "default"], actor: actor)
        {:ok, command} = AgentCommand.acknowledge(command, [message: "ack"], actor: actor)
        command
    end
  end
end
