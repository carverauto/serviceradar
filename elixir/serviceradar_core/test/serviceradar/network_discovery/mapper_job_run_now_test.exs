defmodule ServiceRadar.NetworkDiscovery.MapperJobRunNowTest do
  use ServiceRadar.DataCase, async: false

  alias Ash.Error.Changes.InvalidChanges
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.TestSupport

  @moduletag :integration

  @no_online_mapper_message "No online mapper-capable agent is available for this discovery job. Connect one in the selected partition or assign an online mapper agent, then try again."
  @assigned_mapper_offline_message "The assigned mapper agent is offline. Reconnect it or assign an online mapper agent, then try again."

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "run_now reports an actionable validation error when no mapper agent is online" do
    actor = SystemActor.system(:mapper_job_run_now_test)
    unique = System.unique_integer([:positive])

    assert {:ok, job} =
             MapperJob
             |> Ash.Changeset.for_create(
               :create,
               %{name: "Unassigned offline mapper #{unique}", enabled: false},
               actor: actor
             )
             |> Ash.create()

    assert_invalid_assignment(job, actor, @no_online_mapper_message)
  end

  test "run_now reports an actionable validation error when its assigned agent is offline" do
    actor = SystemActor.system(:mapper_job_run_now_test)
    unique = System.unique_integer([:positive])
    agent_id = "offline-mapper-agent-#{unique}"

    assert {:ok, _agent} =
             Agent
             |> Ash.Changeset.for_create(
               :register,
               %{uid: agent_id, metadata: %{"partition_id" => "default"}},
               actor: actor
             )
             |> Ash.create()

    assert {:ok, job} =
             MapperJob
             |> Ash.Changeset.for_create(
               :create,
               %{
                 name: "Assigned offline mapper #{unique}",
                 agent_id: agent_id,
                 enabled: false
               },
               actor: actor
             )
             |> Ash.create()

    assert_invalid_assignment(job, actor, @assigned_mapper_offline_message)
  end

  defp assert_invalid_assignment(job, actor, expected_message) do
    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             job
             |> Ash.Changeset.for_update(:run_now, %{}, actor: actor)
             |> Ash.update()

    assert Enum.any?(errors, fn
             %InvalidChanges{fields: [:agent_id], message: ^expected_message} -> true
             _other -> false
           end)
  end
end
