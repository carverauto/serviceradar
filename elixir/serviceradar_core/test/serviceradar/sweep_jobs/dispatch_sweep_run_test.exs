defmodule ServiceRadar.SweepJobs.DispatchSweepRunTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.SweepJobs.SweepGroup

  test "run_now remains atomic and retains its post-update dispatch hook" do
    action = Ash.Resource.Info.action(SweepGroup, :run_now)

    assert action.require_atomic?

    assert %Ash.Changeset{after_action: [_dispatch]} =
             Ash.Changeset.fully_atomic_changeset(SweepGroup, action, %{},
               actor: SystemActor.system(:dispatch_sweep_run_test)
             )
  end
end
