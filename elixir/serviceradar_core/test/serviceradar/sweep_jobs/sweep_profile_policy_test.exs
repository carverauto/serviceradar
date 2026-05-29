defmodule ServiceRadar.SweepJobs.SweepProfilePolicyTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.Checks.EnablingBannerGrabWithoutPermission
  alias ServiceRadar.SweepJobs.SweepProfile

  @permission "networks.sweeps.banner_grab"

  test "banner grab enable check matches when actor lacks permission" do
    changeset = create_changeset(%{enabled: true})
    actor = %{role: :admin, permissions: MapSet.new()}

    assert EnablingBannerGrabWithoutPermission.match?(actor, %{changeset: changeset},
             permission: @permission
           )
  end

  test "banner grab enable check does not match when actor has permission" do
    changeset = create_changeset(%{enabled: true})
    actor = %{role: :admin, permissions: MapSet.new([@permission])}

    refute EnablingBannerGrabWithoutPermission.match?(actor, %{changeset: changeset},
             permission: @permission
           )
  end

  test "banner grab enable check does not match disabled config" do
    changeset = create_changeset(%{enabled: false})
    actor = %{role: :admin, permissions: MapSet.new()}

    refute EnablingBannerGrabWithoutPermission.match?(actor, %{changeset: changeset},
             permission: @permission
           )
  end

  defp create_changeset(banner_grab) do
    Ash.Changeset.for_create(SweepProfile, :create, %{
      name: "Policy test",
      banner_grab: banner_grab
    })
  end
end
