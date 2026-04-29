defmodule ServiceRadar.Repo.Migrations.CreateFieldsurveyDashboardPlaylistEntries do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:fieldsurvey_dashboard_playlist_entries, primary_key: false, prefix: "platform") do
      add :id, :uuid, primary_key: true
      add :label, :text, null: false
      add :srql_query, :text, null: false
      add :enabled, :boolean, null: false, default: true
      add :sort_order, :integer, null: false, default: 0
      add :overlay_type, :text, null: false, default: "wifi_rssi"
      add :display_mode, :text, null: false, default: "compact_heatmap"
      add :dwell_seconds, :integer, null: false, default: 30
      add :max_age_seconds, :integer, null: false, default: 86_400
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:fieldsurvey_dashboard_playlist_entries, [:enabled, :sort_order],
             prefix: "platform",
             name: :fieldsurvey_dashboard_playlist_enabled_order_idx
           )

    create constraint(:fieldsurvey_dashboard_playlist_entries, :fieldsurvey_dashboard_playlist_label_nonempty,
             check: "length(trim(label)) > 0",
             prefix: "platform"
           )

    create constraint(:fieldsurvey_dashboard_playlist_entries, :fieldsurvey_dashboard_playlist_srql_nonempty,
             check: "length(trim(srql_query)) > 0",
             prefix: "platform"
           )

    create constraint(:fieldsurvey_dashboard_playlist_entries, :fieldsurvey_dashboard_playlist_dwell_bounds,
             check: "dwell_seconds >= 5 AND dwell_seconds <= 3600",
             prefix: "platform"
           )

    create constraint(:fieldsurvey_dashboard_playlist_entries, :fieldsurvey_dashboard_playlist_max_age_bounds,
             check: "max_age_seconds >= 60 AND max_age_seconds <= 31536000",
             prefix: "platform"
           )
  end
end
