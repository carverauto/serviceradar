defmodule ServiceRadar.Repo.Migrations.CreateSeasonalDispositionStates do
  @moduledoc """
  Creates persistent seasonal confirmation state for central anomaly disposition.
  """
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS #{schema()}.seasonal_disposition_states (
      source                  TEXT NOT NULL,
      series_key              TEXT NOT NULL,
      dow                     INTEGER NOT NULL CHECK (dow >= 0 AND dow <= 6),
      hod                     INTEGER NOT NULL CHECK (hod >= 0 AND hod <= 23),
      consecutive_anomalous   INTEGER NOT NULL DEFAULT 0 CHECK (consecutive_anomalous >= 0),
      last_seen_at            TIMESTAMPTZ NOT NULL,
      expires_at              TIMESTAMPTZ,
      metadata                JSONB NOT NULL DEFAULT '{}'::jsonb,
      inserted_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (source, series_key, dow, hod)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_seasonal_disposition_states_expires_at
    ON #{schema()}.seasonal_disposition_states (expires_at)
    WHERE expires_at IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_seasonal_disposition_states_source_seen
    ON #{schema()}.seasonal_disposition_states (source, last_seen_at DESC)
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS #{schema()}.seasonal_disposition_states")
  end

  defp schema, do: prefix() || "platform"
end
