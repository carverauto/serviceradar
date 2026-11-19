defmodule ServiceRadar.Repo.Migrations.RemoveSamlAuthentication do
  @moduledoc """
  Removes SAML single sign-on storage. OIDC and local accounts remain.

  Upgrade behaviour for an install whose authentication settings still select
  SAML: direct SSO is switched off and the mode becomes `password_only`, so
  local password login keeps working. An administrator re-enables SSO by
  configuring OIDC. Users provisioned through SAML keep their rows, roles and
  external ids; only the stored values that name SAML are rewritten, because
  the application can no longer load them:

  - `auth_settings.provider_type = 'saml'` -> NULL (an active SAML login mode
    also becomes `password_only` with SSO disabled);
  - `ng_users.last_auth_method = 'saml'` -> NULL (no recorded method; the next
    login records a new one);
  - `mcp_oauth_grants` with `auth_method = 'saml'` are deleted, and their codes
    and refresh tokens cascade. Such a grant could never refresh (SAML supplied
    no IdP refresh token), so its owner consents again through OIDC.

  Then the SAML columns of `auth_settings` and the two SAML tables
  (`saml_pending_requests`, `saml_consumed_assertions`) are dropped, and
  pending jobs of the removed SAML assertion cleanup worker are deleted so Oban
  does not retry a worker that no longer exists.

  Every statement is idempotent: the drops are `IF EXISTS`, and the rewrites
  match only rows that still carry a SAML value, so a fresh install or a re-run
  changes nothing.

  serviceradar:allow-startup-maintenance - the UPDATE/DELETE statements below
  are bounded by construction: `auth_settings` is a singleton row,
  `ng_users`/`mcp_oauth_grants` are matched on a SAML value that only
  SAML-authenticated users carry, and the Oban delete is limited to one
  removed worker's not-yet-run jobs. They cannot be deferred to a
  post-bootstrap job, because the release that ships this migration no longer
  loads a SAML value: an `ng_users` row still carrying `last_auth_method =
  'saml'` would fail to load until it was rewritten.

  `down` restores the dropped columns and tables (empty) so the previous
  release can boot; the rewritten values are not restored.
  """

  use Ecto.Migration

  @prefix "platform"
  @cleanup_worker "ServiceRadar.Identity.SAMLAssertionCleanupWorker"

  def up do
    execute("""
    UPDATE platform.auth_settings
    SET mode = 'password_only',
        is_enabled = false,
        provider_type = NULL,
        updated_at = now()
    WHERE provider_type = 'saml'
      AND mode = 'active_sso'
    """)

    execute("""
    UPDATE platform.auth_settings
    SET provider_type = NULL,
        updated_at = now()
    WHERE provider_type = 'saml'
    """)

    execute("""
    UPDATE platform.ng_users
    SET last_auth_method = NULL
    WHERE last_auth_method = 'saml'
    """)

    execute("""
    DELETE FROM platform.mcp_oauth_grants
    WHERE auth_method = 'saml'
    """)

    execute("""
    DELETE FROM platform.oban_jobs
    WHERE worker = '#{@cleanup_worker}'
      AND state IN ('available', 'scheduled', 'retryable')
    """)

    execute("""
    ALTER TABLE platform.auth_settings
      DROP COLUMN IF EXISTS saml_idp_metadata_url,
      DROP COLUMN IF EXISTS saml_idp_metadata_xml,
      DROP COLUMN IF EXISTS saml_sp_entity_id,
      DROP COLUMN IF EXISTS encrypted_saml_private_key_encrypted,
      DROP COLUMN IF EXISTS saml_pinned_cert_fingerprints
    """)

    drop_if_exists table(:saml_pending_requests, prefix: @prefix)
    drop_if_exists table(:saml_consumed_assertions, prefix: @prefix)
  end

  def down do
    execute("""
    ALTER TABLE platform.auth_settings
      ADD COLUMN IF NOT EXISTS saml_idp_metadata_url character varying(255),
      ADD COLUMN IF NOT EXISTS saml_idp_metadata_xml text,
      ADD COLUMN IF NOT EXISTS saml_sp_entity_id character varying(255),
      ADD COLUMN IF NOT EXISTS encrypted_saml_private_key_encrypted bytea,
      ADD COLUMN IF NOT EXISTS saml_pinned_cert_fingerprints character varying(255)[]
        DEFAULT ARRAY[]::character varying[]
    """)

    create_if_not_exists table(:saml_consumed_assertions, primary_key: false, prefix: @prefix) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :issuer, :text, null: false
      add :assertion_id, :text, null: false
      add :not_on_or_after, :utc_datetime_usec, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('utc', now())")
    end

    create_if_not_exists unique_index(:saml_consumed_assertions, [:issuer, :assertion_id],
                           prefix: @prefix,
                           name: "saml_consumed_assertions_unique_assertion_index"
                         )

    create_if_not_exists index(:saml_consumed_assertions, [:not_on_or_after], prefix: @prefix)

    create_if_not_exists table(:saml_pending_requests, primary_key: false, prefix: @prefix) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :relay_state_hash, :text, null: false
      add :request_id, :text, null: false
      add :return_to, :text
      add :expires_at, :utc_datetime_usec, null: false

      add :issued_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('utc', now())")
    end

    create_if_not_exists unique_index(:saml_pending_requests, [:relay_state_hash],
                           prefix: @prefix,
                           name: "saml_pending_requests_unique_relay_state_index"
                         )

    create_if_not_exists index(:saml_pending_requests, [:expires_at], prefix: @prefix)
  end
end
