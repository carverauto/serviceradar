defmodule ServiceRadarWebNG.Edge.Workers.RecordEventWorker do
  @moduledoc """
  Oban worker for asynchronously recording edge onboarding audit events.

  Delegates to ServiceRadar.Edge.Workers.RecordEventWorker from serviceradar_core.
  """

  # Delegate to the Ash-based worker in serviceradar_core
  defdelegate enqueue(package_id, event_type, opts \\ []),
    to: ServiceRadar.Edge.Workers.RecordEventWorker
end
