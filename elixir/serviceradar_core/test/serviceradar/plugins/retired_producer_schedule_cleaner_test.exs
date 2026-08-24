defmodule ServiceRadar.Plugins.RetiredProducerScheduleCleanerTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.ProducerSchedule
  alias ServiceRadar.Plugins.RetiredProducerScheduleCleaner

  require Ash.Query

  @moduletag :integration

  # Must match a real entry in ServiceRadar.Plugins.RetiredNativeAddons.
  @retired_addon_id "advisory-producer"

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    actor = %{
      id: Ash.UUID.generate(),
      email: "retired-cleaner-test@serviceradar.local",
      role: :admin,
      permissions: MapSet.new(["settings.plugins.manage", "settings.integrations.manage"])
    }

    {:ok, actor: actor, uid: :erlang.unique_integer([:positive])}
  end

  test "retired native add-on package does not re-seed producer schedules", %{
    actor: actor,
    uid: uid
  } do
    # The package declares a producer schedule, but because its addon_id is
    # retired the ProducerScheduleCatalog guard must skip seeding entirely.
    {:ok, package} = create_retired_package(actor, uid)

    schedules = schedules_for(package.id, actor)
    assert schedules == []
  end

  test "clean/0 removes stale producer schedules for retired native add-ons", %{
    actor: actor,
    uid: uid
  } do
    {:ok, retired_package} = create_retired_package(actor, uid)
    {:ok, live_package} = create_live_package(actor, uid)

    # Simulate the stale demo rows the retired advisory-producer package left
    # behind (the catalog guard prevents the create path from seeding them).
    {:ok, stale} = create_schedule(retired_package.id, "cisa_kev.refresh", actor)
    {:ok, live} = create_schedule(live_package.id, "endpoint.refresh", actor)

    assert :ok = RetiredProducerScheduleCleaner.clean()

    assert {:ok, nil} = fetch_schedule(stale.id, actor)
    assert {:ok, %ProducerSchedule{}} = fetch_schedule(live.id, actor)
  end

  defp create_retired_package(actor, uid) do
    # addon_id MUST be exactly the retired id; version keeps the identity unique
    # across test runs.
    AddonPackage
    |> Ash.Changeset.for_create(
      :create,
      package_attrs(@retired_addon_id, uid, with_schedule: true),
      actor: actor
    )
    |> Ash.create()
  end

  defp create_live_package(actor, uid) do
    AddonPackage
    |> Ash.Changeset.for_create(
      :create,
      package_attrs("not-retired-addon-#{uid}", uid, with_schedule: false),
      actor: actor
    )
    |> Ash.create()
  end

  defp package_attrs(addon_id, uid, opts) do
    schedules =
      if Keyword.get(opts, :with_schedule, false) do
        [
          %{
            "schedule_id" => "cisa_kev.refresh",
            "label" => "Refresh CISA KEV",
            "action_id" => "cisa_kev.refresh",
            "command_type" => "addon.run_command",
            "default_cadence_seconds" => 86_400,
            "min_cadence_seconds" => 3_600,
            "max_cadence_seconds" => 2_592_000,
            "settings_schema" => %{"type" => "object"}
          }
        ]
      else
        []
      end

    %{
      addon_id: addon_id,
      name: "Retired Cleaner Test #{uid}",
      version: "1.0.#{uid}",
      delivery: :pushed_artifact,
      supervision: :agent_sidecar,
      binary: "serviceradar-retired-cleaner-test",
      capabilities: ["producer-schedule:v1"],
      config_schema: %{},
      producer_schedules: schedules,
      artifacts: %{},
      requires: %{},
      source_type: :upload
    }
  end

  defp create_schedule(addon_package_id, schedule_id, actor) do
    ProducerSchedule
    |> Ash.Changeset.for_create(
      :create,
      %{
        producer_kind: :native_addon,
        addon_package_id: addon_package_id,
        schedule_id: schedule_id,
        display_name: schedule_id,
        contract: %{"action_id" => schedule_id},
        schedule_type: :manual
      },
      actor: actor
    )
    |> Ash.create()
  end

  defp schedules_for(addon_package_id, actor) do
    ProducerSchedule
    |> Ash.Query.filter(addon_package_id == ^addon_package_id)
    |> Ash.read!(actor: actor)
  end

  defp fetch_schedule(id, actor) do
    ProducerSchedule
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(actor: actor)
  end
end
