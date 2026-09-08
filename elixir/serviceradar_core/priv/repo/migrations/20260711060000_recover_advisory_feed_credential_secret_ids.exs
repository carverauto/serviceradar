defmodule ServiceRadar.Repo.Migrations.RecoverAdvisoryFeedCredentialSecretIds do
  @moduledoc """
  Forward recovery for advisory producer credentials.

  The initial retirement migration was deployed before its credential-copy SQL
  was added, so editing that historical migration could not repair databases
  that had already run it. This migration is intentionally idempotent: it
  normalizes legacy network-credential references already copied into feed rows
  and recovers a still-present retired producer reference when one exists.

  Only references that point to an existing VulnCheck `NetworkCredentialSecret`
  are accepted. Arbitrary strings and plaintext tokens are never copied into a
  feed definition.
  """

  use Ecto.Migration

  @addon_id "advisory-producer"

  def up do
    # serviceradar:allow-startup-maintenance - this forward recovery is bounded
    # to the two advisory feed definitions, one retired add-on schedule, and one
    # unavailable built-in feed row. Each lookup uses an existing identifier or
    # provider/feed key index; it does not scan or rewrite telemetry data.
    execute("""
    WITH normalized AS (
      SELECT
        definition.id,
        CASE
          WHEN definition.credential_ref LIKE 'credentialref:network-credential-secret:%'
            THEN replace(
              definition.credential_ref,
              'credentialref:network-credential-secret:',
              ''
            )
          ELSE definition.credential_ref
        END AS secret_id
      FROM platform.vulnerability_feed_definitions definition
      WHERE (definition.provider, definition.feed_key) IN (
        ('vulncheck', 'vulncheck-kev'),
        ('nvd', 'nist-nvd2')
      )
        AND NULLIF(definition.credential_ref, '') IS NOT NULL
    )
    UPDATE platform.vulnerability_feed_definitions definition
    SET
      credential_ref = normalized.secret_id,
      metadata = definition.metadata || jsonb_build_object(
        'credential_storage',
        'network_credential_secret'
      ),
      updated_at = (now() AT TIME ZONE 'utc')
    FROM normalized
    JOIN platform.network_credential_secrets secret
      ON secret.id::text = normalized.secret_id
     AND secret.provider = 'vulncheck'
    WHERE definition.id = normalized.id
    """)

    execute("""
    WITH raw_advisory_credentials AS (
      SELECT COALESCE(
        NULLIF(schedule.credential_refs->>'api_token', ''),
        NULLIF(schedule.credential_refs->>'vulncheck_api', ''),
        NULLIF(schedule.credential_refs->>'vulncheck_token', ''),
        NULLIF(schedule.params->>'api_token_secret_ref', ''),
        NULLIF(schedule.params->>'credential_ref', ''),
        NULLIF(schedule.params->>'credential_secret_ref', '')
      ) AS credential_ref
      FROM platform.producer_schedules schedule
      JOIN platform.addon_packages package ON schedule.addon_package_id = package.id
      WHERE package.addon_id = '#{@addon_id}'
      ORDER BY schedule.updated_at DESC NULLS LAST, schedule.inserted_at DESC NULLS LAST
    ),
    normalized_credentials AS (
      SELECT CASE
        WHEN credential_ref LIKE 'credentialref:network-credential-secret:%'
          THEN replace(credential_ref, 'credentialref:network-credential-secret:', '')
        ELSE credential_ref
      END AS secret_id
      FROM raw_advisory_credentials
    ),
    selected_credential AS (
      SELECT normalized_credentials.secret_id
      FROM normalized_credentials
      JOIN platform.network_credential_secrets secret
        ON secret.id::text = normalized_credentials.secret_id
       AND secret.provider = 'vulncheck'
      WHERE normalized_credentials.secret_id IS NOT NULL
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
      selected_credential.secret_id,
      '{}'::jsonb,
      'never',
      jsonb_build_object(
        'migrated_from',
        'advisory-producer',
        'credential_storage',
        'network_credential_secret'
      )
    FROM selected_credential
    CROSS JOIN feed_rows
    ON CONFLICT (provider, feed_key)
    DO UPDATE SET
      credential_ref = COALESCE(
        NULLIF(vulnerability_feed_definitions.credential_ref, ''),
        EXCLUDED.credential_ref
      ),
      enabled = vulnerability_feed_definitions.enabled OR EXCLUDED.enabled,
      metadata = vulnerability_feed_definitions.metadata || jsonb_build_object(
        'credential_storage',
        'network_credential_secret'
      ),
      updated_at = (now() AT TIME ZONE 'utc')
    """)

    execute("""
    UPDATE platform.vulnerability_feed_definitions
    SET
      enabled = false,
      metadata = metadata || jsonb_build_object('unavailable_reason', 'not_implemented'),
      updated_at = (now() AT TIME ZONE 'utc')
    WHERE provider = 'nvd'
      AND feed_key = 'nvd-api'
    """)
  end

  def down do
    :ok
  end
end
