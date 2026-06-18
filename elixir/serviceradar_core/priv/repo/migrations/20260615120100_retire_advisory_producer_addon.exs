defmodule ServiceRadar.Repo.Migrations.RetireAdvisoryProducerAddon do
  @moduledoc """
  Retires the Go `serviceradar-advisory-producer` add-on. Advisory feeds now run
  in core (AshOban-scheduled, disk-staged); the agent-dispatched producer-schedule
  path for advisories is removed.

  This purges, scoped to `addon_id = 'advisory-producer'`:
    * `producer_schedules` rows owned by the advisory add-on package
    * `addon_assignments` for the advisory add-on
    * the advisory `addon_packages` row itself

  The shared dispatcher / assignment / schedule resources are untouched; only the
  advisory-specific rows are removed. Idempotent (safe to re-run); irreversible
  (`down` is a no-op — the core scheduler supersedes the producer schedules).
  """
  use Ecto.Migration

  @addon_id "advisory-producer"

  def up do
    execute("""
    WITH advisory_credentials AS (
      SELECT COALESCE(
        NULLIF(ps.credential_refs->>'api_token', ''),
        NULLIF(ps.credential_refs->>'vulncheck_api', ''),
        NULLIF(ps.credential_refs->>'vulncheck_token', ''),
        NULLIF(ps.params->>'api_token', ''),
        NULLIF(ps.params->>'api_token_secret_ref', ''),
        NULLIF(ps.params->>'credential_ref', ''),
        NULLIF(ps.params->>'credential_secret_ref', '')
      ) AS credential_ref
      FROM platform.producer_schedules ps
      JOIN platform.addon_packages ap ON ps.addon_package_id = ap.id
      WHERE ap.addon_id = '#{@addon_id}'
      ORDER BY ps.updated_at DESC NULLS LAST, ps.inserted_at DESC NULLS LAST
    ),
    selected_credential AS (
      SELECT credential_ref
      FROM advisory_credentials
      WHERE credential_ref IS NOT NULL
      LIMIT 1
    ),
    feed_rows(provider, feed_key, display_name) AS (
      VALUES
        ('vulncheck', 'vulncheck-kev', 'VulnCheck KEV'),
        ('nvd', 'nist-nvd2', 'VulnCheck nist-nvd2 (NVD CPE)')
    )
    INSERT INTO platform.vulnerability_feed_definitions (
      provider,
      feed_key,
      display_name,
      feed_type,
      enabled,
      refresh_interval_seconds,
      retention_days,
      credential_ref,
      options,
      last_status,
      metadata
    )
    SELECT
      feed_rows.provider,
      feed_rows.feed_key,
      feed_rows.display_name,
      'addon_normalized_advisory_feed',
      true,
      21600,
      30,
      selected_credential.credential_ref,
      '{}'::jsonb,
      'never',
      jsonb_build_object('migrated_from', 'advisory-producer')
    FROM selected_credential
    CROSS JOIN feed_rows
    ON CONFLICT (provider, feed_key)
    DO UPDATE SET
      credential_ref = COALESCE(
        NULLIF(vulnerability_feed_definitions.credential_ref, ''),
        EXCLUDED.credential_ref
      ),
      enabled = vulnerability_feed_definitions.enabled OR EXCLUDED.enabled,
      updated_at = (now() AT TIME ZONE 'utc')
    """)

    execute("""
    DELETE FROM platform.producer_schedules ps
    USING platform.addon_packages ap
    WHERE ps.addon_package_id = ap.id
      AND ap.addon_id = '#{@addon_id}'
    """)

    execute("""
    DELETE FROM platform.addon_assignments
    WHERE addon_id = '#{@addon_id}'
    """)

    execute("""
    DELETE FROM platform.addon_packages
    WHERE addon_id = '#{@addon_id}'
    """)
  end

  def down do
    # Irreversible: the advisory add-on is retired in favor of core feed workers.
    :ok
  end
end
