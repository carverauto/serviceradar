defmodule ServiceRadar.Repo.Migrations.CreateAuthSettings do
  @moduledoc """
  Creates the auth_settings table for instance-level authentication configuration.

  This table stores SSO configuration (OIDC, SAML, Proxy JWT) for the instance.
  It uses a singleton constraint to ensure only one configuration row exists.
  """

  use Ecto.Migration

  def up do
    create table(:auth_settings, primary_key: false, prefix: "platform") do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      # Mode selection: password_only, active_sso, passive_proxy
      add :mode, :string, null: false, default: "password_only"

      # Provider type (when mode = active_sso): oidc, saml
      add :provider_type, :string

      # OIDC Configuration
      add :oidc_client_id, :string
      # AshCloak adds 'encrypted_' prefix to storage column
      add :encrypted_oidc_client_secret_encrypted, :binary
      add :oidc_discovery_url, :string
      add :oidc_scopes, :string, default: "openid email profile"

      # SAML Configuration
      add :saml_idp_metadata_url, :string
      add :saml_idp_metadata_xml, :text
      add :saml_sp_entity_id, :string
      # AshCloak adds 'encrypted_' prefix to storage column
      add :encrypted_saml_private_key_encrypted, :binary
      # Pinned certificate fingerprints for additional security
      add :saml_pinned_cert_fingerprints, {:array, :string}, default: []

      # Proxy JWT Configuration (for Kong/gateway)
      add :jwt_public_key_pem, :text
      add :jwt_jwks_url, :string
      add :jwt_issuer, :string
      add :jwt_audience, :string
      add :jwt_header_name, :string, default: "Authorization"

      # Claim mappings (JSON)
      add :claim_mappings, :map, default: %{"email" => "email", "name" => "name", "sub" => "sub"}

      # Feature flags
      add :is_enabled, :boolean, default: false
      add :allow_password_fallback, :boolean, default: true

      # Audit timestamps
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    # Singleton constraint - only one auth_settings row per instance
    # Use expression index with constant value to ensure only one row can exist
    execute "CREATE UNIQUE INDEX auth_settings_singleton ON platform.auth_settings ((1))"

    # Insert default row
    execute """
    INSERT INTO platform.auth_settings (id, mode, is_enabled, allow_password_fallback)
    VALUES (gen_random_uuid(), 'password_only', false, true)
    ON CONFLICT DO NOTHING
    """
  end

  def down do
    drop table(:auth_settings, prefix: "platform")
  end
end
