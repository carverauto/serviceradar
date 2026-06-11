defmodule ServiceRadar.Plugins.AddonProfileActionTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonProfile

  test "preview and reconcile actions return structured errors instead of treating context as Access" do
    actor = SystemActor.system(:addon_profile_action_test)
    missing_id = Ecto.UUID.generate()

    assert {:error, _reason} =
             AddonProfile
             |> Ash.ActionInput.for_action(:preview, %{id: missing_id, sample_limit: 1})
             |> Ash.run_action(actor: actor)

    assert {:error, _reason} =
             AddonProfile
             |> Ash.ActionInput.for_action(:reconcile_now, %{id: missing_id})
             |> Ash.run_action(actor: actor)
  end
end
