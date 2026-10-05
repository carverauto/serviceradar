defmodule ServiceRadar.Repo.Migrations.AddInterfaceThresholdStates do
  @moduledoc """
  Durable evaluation state for `ServiceRadar.Inventory.InterfaceThresholdWorker`.

  One row per interface setting and metric that is currently violating its
  threshold (`violation_started_at`, for the duration check) or inside the
  alert cooldown that follows an event (`last_alert_at`). The worker deletes a
  row once neither applies, and deleting the interface setting cascades.

  The worker used to keep this in node-local `:persistent_term` keyed by
  monotonic time, which was lost whenever the job ran on another node, never
  cleaned up its cooldown keys, and compared a negative monotonic clock with a
  default of 0, so no threshold ever left its "cooldown" and none ever fired.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS platform.interface_threshold_states (
      interface_settings_id uuid NOT NULL
        REFERENCES platform.interface_settings(id) ON DELETE CASCADE,
      metric_name text NOT NULL,
      violation_started_at timestamptz,
      last_alert_at timestamptz,
      updated_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (interface_settings_id, metric_name)
    )
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS platform.interface_threshold_states")
  end
end
