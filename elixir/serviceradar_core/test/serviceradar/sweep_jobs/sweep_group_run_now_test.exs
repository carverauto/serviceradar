defmodule ServiceRadar.SweepJobs.SweepGroupRunNowTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
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

    assert {:ok, group} =
             SweepGroup
             |> Ash.Changeset.for_create(
               :create,
               %{
                 name: "Offline run-now group #{unique}",
                 agent_id: agent_id,
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
  end
end
