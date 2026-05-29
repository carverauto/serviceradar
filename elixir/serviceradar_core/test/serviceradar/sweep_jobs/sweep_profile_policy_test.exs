defmodule ServiceRadar.SweepJobs.SweepProfilePolicyTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.Checks.EnablingBannerGrabWithoutPermission
  alias ServiceRadar.SweepJobs.SweepProfile
  alias ServiceRadar.SweepJobs.SweepProfile.BannerGrab

  @permission "networks.sweeps.banner_grab"

  test "banner grab check matches when actor lacks permission to enable" do
    changeset = create_changeset(%{enabled: true})
    actor = %{role: :admin, permissions: MapSet.new()}

    assert EnablingBannerGrabWithoutPermission.match?(actor, %{changeset: changeset},
             permission: @permission
           )
  end

  test "banner grab check matches when actor lacks permission to mutate enabled config" do
    changeset =
      update_changeset(%{
        enabled: true,
        protocols: [:ssh],
        max_global_concurrency: 512
      })

    actor = %{role: :admin, permissions: MapSet.new()}

    assert EnablingBannerGrabWithoutPermission.match?(actor, %{changeset: changeset},
             permission: @permission
           )
  end

  test "banner grab check does not match unrelated updates while enabled" do
    profile = enabled_profile()

    changeset =
      Ash.Changeset.for_update(profile, :update, %{
        name: "Policy test renamed"
      })

    actor = %{role: :admin, permissions: MapSet.new()}

    refute EnablingBannerGrabWithoutPermission.match?(actor, %{changeset: changeset},
             permission: @permission
           )
  end

  test "banner grab check does not match when actor has permission" do
    changeset = create_changeset(%{enabled: true})
    actor = %{role: :admin, permissions: MapSet.new([@permission])}

    refute EnablingBannerGrabWithoutPermission.match?(actor, %{changeset: changeset},
             permission: @permission
           )
  end

  test "banner grab check does not match disabled config" do
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

  defp update_changeset(banner_grab) do
    Ash.Changeset.for_update(enabled_profile(), :update, %{banner_grab: banner_grab})
  end

  defp enabled_profile do
    %SweepProfile{
      id: Ash.UUID.generate(),
      name: "Policy test",
      banner_grab: %BannerGrab{
        enabled: true,
        protocols: [:ssh],
        ports: %{},
        connect_timeout_ms: 2_000,
        read_timeout_ms: 2_000,
        max_banner_bytes: 1_024,
        max_concurrency_per_host: 4,
        max_global_concurrency: 256,
        max_probe_rate_per_second: 0,
        max_candidate_queue: 8_192,
        match_batch_size: 256,
        match_batch_max_bytes: 1_048_576,
        min_reprobe_interval_s: 86_400,
        per_host_rate_limit_ms: 100
      }
    }
  end
end
