defmodule ServiceRadar.Repo.Migrations.AddNetflowOptionalSecurityAndIpinfoSettings do
  @moduledoc """
  Adds optional NetFlow enrichment/security settings and caches.

  This migration introduces:
  - `platform.netflow_settings` singleton row for deployment-level settings (encrypted API keys)
  - `platform.ip_ipinfo_cache` bounded cache for ipinfo.io/lite enrichment
  - `platform.threat_intel_indicators` feed-backed indicator table (CIDR-based)
  - `platform.ip_threat_intel_cache` bounded cache for per-IP indicator matches
  - `platform.netflow_port_scan_flags` bounded cache for port-scan heuristics
  - `platform.netflow_port_anomaly_flags` bounded cache for simple port anomalies
  """

  use Ecto.Migration

  def up do
    create table(:netflow_settings, primary_key: false, prefix: "platform") do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      # External enrichment provider(s)
      add :ipinfo_enabled, :boolean, null: false, default: false
      add :ipinfo_base_url, :text, null: false, default: "https://api.ipinfo.io"
      add :encrypted_ipinfo_api_key, :binary

      # Security intelligence flags (feature-flagged)
      add :threat_intel_enabled, :boolean, null: false, default: false
      add :threat_intel_feed_urls, {:array, :text}, null: false, default: []

      add :anomaly_enabled, :boolean, null: false, default: false
      add :anomaly_baseline_window_seconds, :integer, null: false, default: 604_800
      add :anomaly_threshold_percent, :integer, null: false, default: 300

      add :port_scan_enabled, :boolean, null: false, default: false
      add :port_scan_window_seconds, :integer, null: false, default: 300
      add :port_scan_unique_ports_threshold, :integer, null: false, default: 50

      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    # Singleton constraint - only one netflow_settings row per instance
    execute "CREATE UNIQUE INDEX netflow_settings_singleton ON platform.netflow_settings ((1))"

    # Insert default row
    execute """
    INSERT INTO platform.netflow_settings (id)
    VALUES (gen_random_uuid())
    ON CONFLICT DO NOTHING
    """

    create table(:ip_ipinfo_cache, primary_key: false, prefix: "platform") do
      add :ip, :text, primary_key: true, null: false

      # ipinfo.io/lite fields (subset; we store only lightweight fields)
      add :country_code, :text
      add :country_name, :text
      add :region, :text
      add :city, :text
      add :timezone, :text
      add :as_number, :integer
      add :as_name, :text
      add :as_domain, :text

      add :looked_up_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :error, :text
      add :error_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ip_ipinfo_cache, [:expires_at], prefix: "platform")
    create index(:ip_ipinfo_cache, [:as_number], prefix: "platform")
    create index(:ip_ipinfo_cache, [:country_code], prefix: "platform")

    create table(:threat_intel_indicators, primary_key: false, prefix: "platform") do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :indicator, :cidr, null: false
      add :indicator_type, :text, null: false, default: "cidr"
      add :source, :text, null: false
      add :label, :text
      add :severity, :integer
      add :confidence, :integer

      add :first_seen_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :last_seen_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:threat_intel_indicators, [:source], prefix: "platform")
    create index(:threat_intel_indicators, [:expires_at], prefix: "platform")

    execute """
    CREATE INDEX threat_intel_indicators_indicator_gist_idx
    ON platform.threat_intel_indicators
    USING GIST (indicator inet_ops)
    """

    create unique_index(:threat_intel_indicators, [:source, :indicator],
             prefix: "platform",
             name: "threat_intel_indicators_source_indicator_uidx"
           )

    create table(:ip_threat_intel_cache, primary_key: false, prefix: "platform") do
      add :ip, :text, primary_key: true, null: false

      add :matched, :boolean, null: false, default: false
      add :match_count, :integer, null: false, default: 0
      add :max_severity, :integer
      add :sources, {:array, :text}, null: false, default: []

      add :looked_up_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :error, :text
      add :error_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ip_threat_intel_cache, [:expires_at], prefix: "platform")
    create index(:ip_threat_intel_cache, [:matched], prefix: "platform")

    create table(:netflow_port_scan_flags, primary_key: false, prefix: "platform") do
      add :src_ip, :text, primary_key: true, null: false

      add :unique_ports, :integer, null: false
      add :window_seconds, :integer, null: false
      add :window_end, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:netflow_port_scan_flags, [:expires_at], prefix: "platform")
    create index(:netflow_port_scan_flags, [:unique_ports], prefix: "platform")

    create table(:netflow_port_anomaly_flags, primary_key: false, prefix: "platform") do
      add :dst_port, :integer, primary_key: true, null: false

      add :current_bytes, :bigint, null: false
      add :baseline_bytes, :bigint, null: false
      add :threshold_percent, :integer, null: false
      add :window_seconds, :integer, null: false
      add :window_end, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:netflow_port_anomaly_flags, [:expires_at], prefix: "platform")
  end

  def down do
    drop table(:netflow_port_anomaly_flags, prefix: "platform")
    drop table(:netflow_port_scan_flags, prefix: "platform")
    drop table(:ip_threat_intel_cache, prefix: "platform")
    drop table(:threat_intel_indicators, prefix: "platform")
    drop table(:ip_ipinfo_cache, prefix: "platform")
    drop table(:netflow_settings, prefix: "platform")
  end
end

