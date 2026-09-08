defmodule ServiceRadarWebNG.Plugins.FirstPartySyncScheduler do
  @moduledoc """
  Ensures the first-party Wasm plugin sync worker is scheduled when enabled.
  """

  use ServiceRadar.ObanEnsureScheduled,
    workers: [ServiceRadarWebNG.Plugins.FirstPartySyncWorker],
    label: "First-party Wasm plugin sync scheduler",
    tick: :schedule_first_party_plugin_sync,
    named_start?: true
end
