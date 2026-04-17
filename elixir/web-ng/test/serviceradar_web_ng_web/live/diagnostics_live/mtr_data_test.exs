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

  test "list_bulk_jobs matches targets from bulk payloads", %{actor: actor, scope: scope} do
    unrelated =
      create_bulk_mtr_command(actor, "agent-other", ["203.0.113.10", "router-other"],
        inserted_at: DateTime.add(DateTime.utc_now(), -30, :second)
      )

    matching =
      create_bulk_mtr_command(actor, "agent-bulk", ["192.0.2.10", "core-sw01"],
        inserted_at: DateTime.add(DateTime.utc_now(), -5, :second)
      )

    assert {:ok, jobs} = MtrData.list_bulk_jobs(scope, target_filter: "core-sw01")

    assert Enum.map(jobs, & &1.id) == [matching.id]
    refute Enum.any?(jobs, &(&1.id == unrelated.id))
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

  defp create_bulk_mtr_command(actor, agent_id, targets, opts) do
    inserted_at = Keyword.get(opts, :inserted_at, DateTime.utc_now())

    {:ok, command} =
      AgentCommand.create_command(
        %{
          command_type: "mtr.bulk_run",
          agent_id: agent_id,
          partition_id: "default",
          payload: %{"targets" => targets, "protocol" => "icmp"},
          ttl_seconds: 300,
          expires_at: DateTime.add(inserted_at, 300, :second)
        },
        actor: actor
      )

    {:ok, command} = AgentCommand.mark_sent(command, [partition_id: "default"], actor: actor)

    {:ok, command} =
      AgentCommand.complete(command, [message: "done", result_payload: %{"total_targets" => 2}], actor: actor)

    ServiceRadar.Repo.query!(
      "UPDATE platform.agent_commands SET inserted_at = $2, completed_at = $3 WHERE id = $1",
      [command.id, inserted_at, DateTime.add(inserted_at, 10, :second)]
    )

    %{command | inserted_at: inserted_at, completed_at: DateTime.add(inserted_at, 10, :second)}
  end
end
