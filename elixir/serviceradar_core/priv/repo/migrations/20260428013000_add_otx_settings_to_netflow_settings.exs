defmodule ServiceRadar.Repo.Migrations.AddOtxSettingsToNetflowSettings do
  @moduledoc false
  use Ecto.Migration

  def up do
    alter table(:netflow_settings, prefix: "platform") do
      add :otx_enabled, :boolean, null: false, default: false
      add :otx_execution_mode, :text, null: false, default: "edge_plugin"
      add :otx_base_url, :text, null: false, default: "https://otx.alienvault.com"
      add :encrypted_otx_api_key, :binary
      add :otx_sync_interval_seconds, :integer, null: false, default: 3_600
      add :otx_page_size, :integer, null: false, default: 100
      add :otx_timeout_ms, :integer, null: false, default: 120_000
      add :otx_max_indicators, :integer, null: false, default: 5_000
      add :otx_modified_since, :text
      add :otx_raw_payload_archive_enabled, :boolean, null: false, default: false
      add :otx_retrohunt_window_seconds, :integer, null: false, default: 7_776_000
      add :threat_intel_match_window_seconds, :integer, null: false, default: 3_600
    end
  end

  def down do
    alter table(:netflow_settings, prefix: "platform") do
      remove :threat_intel_match_window_seconds
      remove :otx_retrohunt_window_seconds
      remove :otx_raw_payload_archive_enabled
      remove :otx_modified_since
      remove :otx_max_indicators
      remove :otx_timeout_ms
      remove :otx_page_size
      remove :otx_sync_interval_seconds
      remove :encrypted_otx_api_key
      remove :otx_base_url
      remove :otx_execution_mode
      remove :otx_enabled
    end
  end
end
