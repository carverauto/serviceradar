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

  test "list_bulk_jobs excludes expired active bulk commands", %{actor: actor, scope: scope} do
    stale =
      create_bulk_mtr_command(actor, "agent-stale", ["192.0.2.10"],
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second),
        status: :queued
      )

    recent =
      create_bulk_mtr_command(actor, "agent-recent", ["192.0.2.20"],
        inserted_at: DateTime.add(DateTime.utc_now(), -5, :second)
      )

    assert {:ok, jobs} = MtrData.list_bulk_jobs(scope)

    job_ids = MapSet.new(Enum.map(jobs, & &1.id))

    refute MapSet.member?(job_ids, stale.id)
    assert MapSet.member?(job_ids, recent.id)
  end

  test "list_traces_paginated applies relative MTR time filters" do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    old_time = DateTime.add(now, -2, :day)

    old_id = insert_mtr_trace!("agent-time", "198.51.100.10", old_time)
    fresh_id = insert_mtr_trace!("agent-time", "198.51.100.20", now)

    assert {:ok, %{rows: rows, total_count: 1}} =
             MtrData.list_traces_paginated(srql_query: "in:mtr_traces time:last_1h", limit: 50)

    ids = Enum.map(rows, & &1["id"])
    assert fresh_id in ids
    refute old_id in ids
  end

  test "list_traces_paginated applies absolute MTR time ranges" do
    inside_time = ~U[2026-05-07 10:00:00Z]
    outside_time = ~U[2026-05-09 10:00:00Z]

    inside_id = insert_mtr_trace!("agent-absolute", "203.0.113.10", inside_time)
    outside_id = insert_mtr_trace!("agent-absolute", "203.0.113.20", outside_time)

    query = "in:mtr_traces time:[2026-05-07T00:00:00Z,2026-05-08T00:00:00Z]"

    assert {:ok, %{rows: rows, total_count: 1}} =
             MtrData.list_traces_paginated(srql_query: query, limit: 50)

    ids = Enum.map(rows, & &1["id"])
    assert inside_id in ids
    refute outside_id in ids
  end

  test "list_traces_paginated uses stable pages for equal timestamps" do
    timestamp = DateTime.truncate(DateTime.utc_now(), :second)

    ids =
      for target <- ["192.0.2.101", "192.0.2.102", "192.0.2.103"] do
        insert_mtr_trace!("agent-stable", target, timestamp)
      end

    assert {:ok, %{rows: page_1}} =
             MtrData.list_traces_paginated(
               srql_query: "in:mtr_traces agent_id:agent-stable sort:time:desc",
               limit: 2,
               page: 1
             )

    assert {:ok, %{rows: page_2}} =
             MtrData.list_traces_paginated(
               srql_query: "in:mtr_traces agent_id:agent-stable sort:time:desc",
               limit: 2,
               page: 2
             )

    page_1_ids = MapSet.new(Enum.map(page_1, & &1["id"]))
    page_2_ids = MapSet.new(Enum.map(page_2, & &1["id"]))

    assert MapSet.disjoint?(page_1_ids, page_2_ids)
    assert MapSet.subset?(MapSet.union(page_1_ids, page_2_ids), MapSet.new(ids))
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
    expires_at = Keyword.get(opts, :expires_at, DateTime.add(inserted_at, 300, :second))
    status = Keyword.get(opts, :status, :completed)

    {:ok, command} =
      AgentCommand.create_command(
        %{
          command_type: "mtr.bulk_run",
          agent_id: agent_id,
          partition_id: "default",
          payload: %{"targets" => targets, "protocol" => "icmp"},
          ttl_seconds: 300,
          expires_at: expires_at
        },
        actor: actor
      )

    command =
      case status do
        :queued ->
          command

        :sent ->
          {:ok, command} =
            AgentCommand.mark_sent(command, [partition_id: "default"], actor: actor)

          command

        :acknowledged ->
          {:ok, command} =
            AgentCommand.mark_sent(command, [partition_id: "default"], actor: actor)

          {:ok, command} = AgentCommand.acknowledge(command, [message: "ack"], actor: actor)
          command

        :running ->
          {:ok, command} =
            AgentCommand.mark_sent(command, [partition_id: "default"], actor: actor)

          {:ok, command} = AgentCommand.start(command, [message: "running"], actor: actor)
          command

        :completed ->
          {:ok, command} =
            AgentCommand.mark_sent(command, [partition_id: "default"], actor: actor)

          {:ok, command} =
            AgentCommand.complete(
              command,
              [message: "done", result_payload: %{"total_targets" => 2}],
              actor: actor
            )

          command
      end

    completed_at =
      case status do
        :completed -> DateTime.add(inserted_at, 10, :second)
        _ -> nil
      end

    ServiceRadar.Repo.query!(
      "UPDATE platform.agent_commands SET inserted_at = $2, completed_at = $3, expires_at = $4 WHERE command_id = $1",
      [dump_uuid!(command.id), inserted_at, completed_at, expires_at]
    )

    %{command | inserted_at: inserted_at, completed_at: completed_at, expires_at: expires_at}
  end

  defp insert_mtr_trace!(agent_id, target_ip, timestamp) do
    id = Ecto.UUID.generate()
    db_id = dump_uuid!(id)

    ServiceRadar.Repo.insert_all("mtr_traces", [
      %{
        id: db_id,
        time: timestamp,
        agent_id: agent_id,
        gateway_id: "gateway-test",
        check_id: "check-#{id}",
        check_name: "MTR #{target_ip}",
        device_id: nil,
        target: target_ip,
        target_ip: target_ip,
        target_reached: true,
        total_hops: 8,
        protocol: "icmp",
        ip_version: 4,
        packet_size: 64,
        partition: "default",
        error: nil,
        created_at: timestamp
      }
    ])

    id
  end

  defp dump_uuid!(uuid) do
    case Ecto.UUID.dump(uuid) do
      {:ok, dumped} -> dumped
      :error -> uuid
    end
  end
end
