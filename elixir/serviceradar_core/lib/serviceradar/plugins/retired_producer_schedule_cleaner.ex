defmodule ServiceRadar.Plugins.RetiredProducerScheduleCleaner do
  @moduledoc """
  Removes stale `producer_schedules` rows that belong to a retired native add-on.

  When a first-party native add-on is retired (see
  `ServiceRadar.Plugins.RetiredNativeAddons`) the capability moves out of the
  agent command-bus path, but any producer-schedule rows the old package seeded
  linger in `platform.producer_schedules`. The Vulnerability Intelligence page
  used to surface these advisory rows (cisa_kev.refresh / nvd_cve.refresh /
  vulncheck.refresh) under "Scheduled Producers", even though no enabled
  assignment can ever dispatch them.

  This boot-time, idempotent cleanup deletes producer-schedule rows whose
  `addon_package_id` belongs to an `AddonPackage` whose `addon_id` is retired.
  It is keyed on `RetiredNativeAddons.ids/0`, so it generalizes to any future
  retirement rather than hard-coding the three demo UUIDs.

  The generic producer-schedule subsystem (`ProducerSchedule`,
  `ProducerScheduleCatalog`, `ProducerScheduleDispatcher`) is untouched — only
  the retired-add-on rows are pruned, and re-seeding is independently prevented
  by the guard in `ProducerScheduleCatalog.sync_package/2`.
  """

  use ServiceRadar.DelayedSeeder, callback: :clean

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.ProducerSchedule
  alias ServiceRadar.Plugins.RetiredNativeAddons

  require Ash.Query
  require Logger

  @spec clean() :: :ok
  def clean do
    if repo_enabled?() do
      actor = SystemActor.system(:retired_producer_schedule_cleaner)

      RetiredNativeAddons.ids()
      |> Enum.flat_map(&retired_package_ids(&1, actor))
      |> destroy_schedules(actor)
    end

    :ok
  end

  defp retired_package_ids(addon_id, actor) do
    case AddonPackage
         |> Ash.Query.for_read(:by_addon_id, %{addon_id: addon_id}, actor: actor)
         |> Ash.read(actor: actor) do
      {:ok, packages} ->
        Enum.map(packages, & &1.id)

      {:error, reason} ->
        Logger.warning(
          "retired_producer_schedule_cleaner: lookup failed for #{addon_id}: #{inspect(reason)}"
        )

        []
    end
  end

  defp destroy_schedules([], _actor), do: :ok

  defp destroy_schedules(package_ids, actor) do
    case ProducerSchedule
         |> Ash.Query.filter(addon_package_id in ^package_ids)
         |> Ash.read(actor: actor) do
      {:ok, []} ->
        :ok

      {:ok, schedules} ->
        Enum.each(schedules, &destroy_schedule(&1, actor))

      {:error, reason} ->
        Logger.warning(
          "retired_producer_schedule_cleaner: schedule read failed: #{inspect(reason)}"
        )
    end
  end

  defp destroy_schedule(schedule, actor) do
    case Ash.destroy(schedule, actor: actor) do
      :ok ->
        log_destroyed(schedule)

      {:ok, _destroyed} ->
        log_destroyed(schedule)

      {:error, reason} ->
        Logger.warning(
          "retired_producer_schedule_cleaner: destroy failed for #{schedule.id}: #{inspect(reason)}"
        )
    end
  end

  defp log_destroyed(schedule) do
    Logger.info(
      "retired_producer_schedule_cleaner: removed retired producer schedule " <>
        "#{schedule.schedule_id} (#{schedule.id})"
    )
  end
end
