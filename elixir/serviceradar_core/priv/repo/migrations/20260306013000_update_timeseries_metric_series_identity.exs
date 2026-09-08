defmodule ServiceRadar.Repo.Migrations.UpdateTimeseriesMetricSeriesIdentity do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE platform.timeseries_metrics
    ADD COLUMN IF NOT EXISTS series_key TEXT
    """)

    execute("""
    CREATE OR REPLACE FUNCTION platform.timeseries_series_component(p_name text, p_value text)
    RETURNS text
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    AS $$
      SELECT CASE
        WHEN p_value IS NULL OR btrim(p_value) = '' THEN NULL
        ELSE octet_length(p_name)::text || ':' || p_name || '=' ||
             octet_length(p_value)::text || ':' || p_value
      END
    $$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION platform.timeseries_series_stable_tags(p_tags jsonb)
    RETURNS text
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    AS $$
      SELECT string_agg(
        platform.timeseries_series_component('tag:' || entry.key, entry.value),
        '|' ORDER BY entry.key
      )
      FROM jsonb_each_text(COALESCE(p_tags, '{}'::jsonb)) AS entry(key, value)
      WHERE COALESCE(btrim(entry.value), '') <> ''
        AND entry.key NOT IN ('available', 'metric', 'packet_loss')
    $$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION platform.build_timeseries_series_key(
      p_metric_type text,
      p_metric_name text,
      p_partition text,
      p_agent_id text,
      p_device_id text,
      p_target_device_ip text,
      p_if_index integer,
      p_tags jsonb
    )
    RETURNS text
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    AS $$
      SELECT md5(
        array_to_string(
          array_remove(
            ARRAY[
              platform.timeseries_series_component('metric_type', p_metric_type),
              platform.timeseries_series_component('metric_name', p_metric_name),
              platform.timeseries_series_component('partition', p_partition),
              platform.timeseries_series_component('agent_id', p_agent_id),
              platform.timeseries_series_component('device_id', p_device_id),
              platform.timeseries_series_component('target_device_ip', p_target_device_ip),
              platform.timeseries_series_component(
                'if_index',
                CASE WHEN p_if_index IS NULL THEN NULL ELSE p_if_index::text END
              ),
              platform.timeseries_series_stable_tags(p_tags)
            ],
            NULL
          ),
          '|'
        )
      )
    $$;
    """)

    execute("""
    UPDATE platform.timeseries_metrics
    SET series_key = platform.build_timeseries_series_key(
      metric_type,
      metric_name,
      partition,
      agent_id,
      device_id,
      target_device_ip,
      if_index,
      tags
    )
    WHERE series_key IS NULL
    """)

    execute("""
    ALTER TABLE platform.timeseries_metrics
    ALTER COLUMN series_key SET NOT NULL
    """)

    execute("""
    ALTER TABLE platform.timeseries_metrics
    DROP CONSTRAINT IF EXISTS timeseries_metrics_pkey
    """)

    execute("""
    ALTER TABLE platform.timeseries_metrics
    ADD CONSTRAINT timeseries_metrics_pkey
    PRIMARY KEY (timestamp, gateway_id, series_key)
    """)
  end

  def down do
    execute("""
    DELETE FROM platform.timeseries_metrics metric
    USING (
      SELECT ctid,
             row_number() OVER (
               PARTITION BY timestamp, gateway_id, metric_name
               ORDER BY created_at DESC, series_key DESC
             ) AS row_num
      FROM platform.timeseries_metrics
    ) duplicates
    WHERE metric.ctid = duplicates.ctid
      AND duplicates.row_num > 1
    """)

    execute("""
    ALTER TABLE platform.timeseries_metrics
    DROP CONSTRAINT IF EXISTS timeseries_metrics_pkey
    """)

    execute("""
    ALTER TABLE platform.timeseries_metrics
    ADD CONSTRAINT timeseries_metrics_pkey
    PRIMARY KEY (timestamp, gateway_id, metric_name)
    """)

    execute("""
    ALTER TABLE platform.timeseries_metrics
    DROP COLUMN IF EXISTS series_key
    """)

    execute(
      "DROP FUNCTION IF EXISTS platform.build_timeseries_series_key(text, text, text, text, text, text, integer, jsonb)"
    )

    execute("DROP FUNCTION IF EXISTS platform.timeseries_series_stable_tags(jsonb)")
    execute("DROP FUNCTION IF EXISTS platform.timeseries_series_component(text, text)")
  end
end
