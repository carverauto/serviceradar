defmodule ServiceRadar.Repo.Migrations.CreateBmpSettings do
  @moduledoc """
  Creates deployment-scoped BMP settings table.
  """

  use Ecto.Migration

  def change do
    create table(:bmp_settings, prefix: "platform") do
      add(:bmp_routing_retention_days, :integer, null: false, default: 3)
      add(:bmp_ocsf_min_severity, :integer, null: false, default: 4)
      add(:god_view_causal_overlay_window_seconds, :integer, null: false, default: 300)
      add(:god_view_causal_overlay_max_events, :integer, null: false, default: 512)
      add(:god_view_routing_causal_severity_threshold, :integer, null: false, default: 4)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:bmp_settings, :bmp_settings_retention_days_check,
        check: "bmp_routing_retention_days BETWEEN 1 AND 30",
        prefix: "platform"
      )
    )

    create(
      constraint(:bmp_settings, :bmp_settings_min_severity_check,
        check: "bmp_ocsf_min_severity BETWEEN 0 AND 6",
        prefix: "platform"
      )
    )

    create(
      constraint(:bmp_settings, :bmp_settings_overlay_window_check,
        check: "god_view_causal_overlay_window_seconds BETWEEN 30 AND 3600",
        prefix: "platform"
      )
    )

    create(
      constraint(:bmp_settings, :bmp_settings_overlay_max_events_check,
        check: "god_view_causal_overlay_max_events BETWEEN 32 AND 10000",
        prefix: "platform"
      )
    )

    create(
      constraint(:bmp_settings, :bmp_settings_overlay_severity_threshold_check,
        check: "god_view_routing_causal_severity_threshold BETWEEN 0 AND 6",
        prefix: "platform"
      )
    )
  end
end
