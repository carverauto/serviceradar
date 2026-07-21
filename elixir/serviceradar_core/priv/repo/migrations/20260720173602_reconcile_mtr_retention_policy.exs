defmodule ServiceRadar.Repo.Migrations.ReconcileMtrRetentionPolicy do
  @moduledoc """
  Preserves migration ordering after MTR Timescale reconciliation moved to the
  idempotent `MtrSettingsSeeder` post-bootstrap path.
  """

  use Ecto.Migration

  # Converting existing Timescale tables and reconciling their policy can scan
  # or lock historical data. MtrSettingsSeeder performs that idempotently after
  # the application has booted instead of extending the migration critical path.
  def up, do: :ok
  def down, do: :ok
end
