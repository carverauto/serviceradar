defmodule ServiceRadar.Observability.ApiEvent.ClearForReplay do
  @moduledoc """
  Clears the rows for every resource opted into `ServiceRadar.Observability.ApiEvent`
  before an event replay, per `AshEvents.ClearRecordsForReplay`.

  Update this list only in lockstep with the `events do event_log ... end`
  opt-ins across the codebase -- currently only
  `ServiceRadar.Observability.StatefulAlertRule`. See
  `openspec/changes/add-ash-events-audit-log/design.md#decisions` for the
  adoption boundary this resource inventory belongs to.
  """

  use AshEvents.ClearRecordsForReplay

  @tables ["stateful_alert_rules"]

  @impl true
  def clear_records!(_opts) do
    Enum.each(@tables, fn table ->
      ServiceRadar.Repo.query!("TRUNCATE TABLE platform.#{table} CASCADE")
    end)

    :ok
  end
end
