defmodule ServiceRadar.SweepJobs.DispatchSweepRunTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.SweepJobs.Changes.NormalizeAgentAssignment
  alias ServiceRadar.SweepJobs.SweepGroup

  test "run_now remains atomic and retains its post-update dispatch hook" do
    action = Info.action(SweepGroup, :run_now)

    assert action.require_atomic?

    assert %Ash.Changeset{after_action: [_dispatch]} =
             Ash.Changeset.fully_atomic_changeset(SweepGroup, action, %{},
               actor: SystemActor.system(:dispatch_sweep_run_test)
             )
  end

  test "create and update normalize a blank Networks UI assignment to all agents" do
    assert normalize_agent_assignment_change?(Info.action(SweepGroup, :create))
    assert normalize_agent_assignment_change?(Info.action(SweepGroup, :update))

    blank =
      Ash.Changeset.for_create(
        SweepGroup,
        :create,
        %{name: "All agents", partition: "default", interval: "15m", agent_id: ""},
        actor: SystemActor.system(:blank_agent_id_test)
      )

    assert is_nil(Ash.Changeset.get_attribute(blank, :agent_id))
    assert Ash.Changeset.get_attribute(blank, :agent_ids) == []
  end

  defp normalize_agent_assignment_change?(action) do
    Enum.any?(action.changes, fn
      %{change: {NormalizeAgentAssignment, _}} -> true
      _ -> false
    end)
  end
end
