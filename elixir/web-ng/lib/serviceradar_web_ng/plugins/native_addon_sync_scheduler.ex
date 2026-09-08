defmodule ServiceRadarWebNG.Plugins.NativeAddonSyncScheduler do
  @moduledoc """
  Ensures the first-party native add-on sync worker is scheduled when enabled.
  """

  use ServiceRadar.ObanEnsureScheduled,
    workers: [ServiceRadarWebNG.Plugins.NativeAddonSyncWorker],
    label: "First-party native add-on sync scheduler",
    tick: :schedule_native_addon_sync,
    named_start?: true
end
