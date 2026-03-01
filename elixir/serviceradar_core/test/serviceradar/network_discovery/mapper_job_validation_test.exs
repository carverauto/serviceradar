defmodule ServiceRadar.NetworkDiscovery.MapperJobValidationTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.NetworkDiscovery.MapperJob

  @tag :integration
  setup do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  @tag :integration
  test "accepts mapper jobs with known agent ids" do
    actor = SystemActor.system(:test)

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(:register, %{uid: "agent-known"}, actor: actor)
      |> Ash.create(actor: actor)

    {:ok, job} =
      MapperJob
      |> Ash.Changeset.for_create(:create, %{name: "job-known", agent_id: "agent-known"},
        actor: actor
      )
      |> Ash.create(actor: actor)

    assert job.agent_id == "agent-known"
  end

  @tag :integration
  test "rejects unknown agent ids" do
    actor = SystemActor.system(:test)

    {:error, %Ash.Error.Invalid{errors: errors}} =
      MapperJob
      |> Ash.Changeset.for_create(:create, %{name: "job-bad", agent_id: "missing-agent"},
        actor: actor
      )
      |> Ash.create(actor: actor)

    assert Enum.any?(errors, &(&1.field == :agent_id))
  end

  @tag :integration
  test "rejects agent ids outside the selected partition" do
    actor = SystemActor.system(:test)

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(
        :register,
        %{uid: "agent-partition", metadata: %{"partition_id" => "lab"}},
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:error, %Ash.Error.Invalid{errors: errors}} =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{name: "job-partition", agent_id: "agent-partition", partition: "default"},
        actor: actor
      )
      |> Ash.create(actor: actor)

    assert Enum.any?(errors, &(&1.field == :agent_id))
  end

  @tag :integration
  test "rejects updates to unknown agent ids" do
    actor = SystemActor.system(:test)

    {:ok, _agent} =
      Agent
      |> Ash.Changeset.for_create(:register, %{uid: "agent-existing"}, actor: actor)
      |> Ash.create(actor: actor)

    {:ok, job} =
      MapperJob
      |> Ash.Changeset.for_create(:create, %{name: "job-update", agent_id: "agent-existing"},
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:error, %Ash.Error.Invalid{errors: errors}} =
      job
      |> Ash.Changeset.for_update(:update, %{agent_id: "missing-agent"}, actor: actor)
      |> Ash.update(actor: actor)

    assert Enum.any?(errors, &(&1.field == :agent_id))
  end
end
