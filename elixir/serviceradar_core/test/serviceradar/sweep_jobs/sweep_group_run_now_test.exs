defmodule ServiceRadar.SweepJobs.SweepGroupRunNowTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentCommands.PubSub, as: AgentCommandPubSub
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "run_now returns the dispatch error for an offline assigned agent" do
    actor = SystemActor.system(:sweep_group_run_now_test)
    unique = System.unique_integer([:positive])
    agent_id = "offline-sweep-agent-#{unique}"
    :ok = AgentCommandPubSub.subscribe()

    assert {:ok, %Agent{uid: ^agent_id, status: :connecting}} =
             Agent
             |> Ash.Changeset.for_create(
               :register,
               %{uid: agent_id, metadata: %{"partition_id" => "default"}},
               actor: actor
             )
             |> Ash.create()

    assert {:ok, group} =
             SweepGroup
             |> Ash.Changeset.for_create(
               :create,
               %{
                 name: "Offline run-now group #{unique}",
                 agent_ids: [agent_id],
                 enabled: false
               },
               actor: actor
             )
             |> Ash.create()

    assert {:error, error} =
             group
             |> Ash.Changeset.for_update(:run_now, %{}, actor: actor)
             |> Ash.update()

    assert %Ash.Error.Unknown{errors: errors} = error

    assert Enum.any?(errors, fn
             %{value: [agent_offline: ^agent_id]} -> true
             _other -> false
           end)

    assert_receive {:sweep_dispatch,
                    %{
                      phase: :started,
                      sweep_dispatch_id: dispatch_id,
                      sweep_dispatch_generation: generation
                    }}

    assert String.match?(generation, ~r/^\d+$/)
    assert String.to_integer(generation) > 0

    assert_receive {:sweep_dispatch,
                    %{
                      phase: :finished,
                      sweep_dispatch_id: ^dispatch_id,
                      sweep_dispatch_generation: ^generation,
                      error: {:agent_offline, ^agent_id}
                    }}
  end
end
