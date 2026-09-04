defmodule ServiceRadar.SweepJobs.SweepHostResultCoverageDbTest do
  use ServiceRadar.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepGroupExecution
  alias ServiceRadar.SweepJobs.SweepHostResult
  alias ServiceRadar.SweepJobs.SweepResultsIngestor

  @moduletag :integration

  test "a second progress batch accumulates coverage and preserves identity" do
    %{execution_id: execution_id, group_id: group_id} = insert_execution()

    first = [
      %{
        "host_ip" => "192.168.50.10",
        "available" => true,
        "port_results" => [%{"port" => 443, "available" => true}]
      }
    ]

    second = [
      %{
        "host_ip" => "192.168.50.10",
        "available" => false,
        "port_results" => [%{"port" => 3001, "available" => false}]
      }
    ]

    ingest(first, execution_id, agent_id: "agent-a", sweep_group_id: group_id)
    ingest(second, execution_id, agent_id: nil, sweep_group_id: nil)

    row = fetch_row(execution_id, "192.168.50.10")

    assert Enum.sort(row.scanned_ports) == [443, 3001]
    assert row.open_ports == []
    assert row.agent_id == "agent-a"
    assert row.sweep_group_id == group_id
  end

  defp ingest(results, execution_id, context) do
    {records, _stats} =
      SweepResultsIngestor.build_host_results(results, execution_id, %{}, context)

    SweepResultsIngestor.bulk_insert_host_results(records)
  end

  defp fetch_row(execution_id, ip) do
    Repo.one!(
      from(r in SweepHostResult,
        where: r.execution_id == ^execution_id and r.ip == ^ip
      )
    )
  end

  defp insert_execution do
    actor = SystemActor.system(:test)
    unique_id = System.unique_integer([:positive, :monotonic])

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Coverage Group #{unique_id}", partition: "default", agent_ids: []},
        actor: actor
      )
      |> Ash.create()

    {:ok, execution} =
      SweepGroupExecution
      |> Ash.Changeset.for_create(
        :start,
        %{sweep_group_id: group.id, agent_id: "agent-a"},
        actor: actor
      )
      |> Ash.create()

    %{execution_id: execution.id, group_id: group.id}
  end
end
