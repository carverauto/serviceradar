defmodule ServiceRadar.Identity.AuthSettings do
  @moduledoc """
  Instance-level authentication configuration.

  This resource stores SSO configuration for the instance, supporting three modes:
  - `password_only` - Standard password authentication (default)
  - `active_sso` - Direct IdP integration (OIDC or SAML)
  - `passive_proxy` - Gateway JWT validation (Kong, Ambassador, etc.)

  ## Singleton Pattern

  Only one AuthSettings row exists per instance. Use `get_settings/0` to retrieve
  the current configuration, which is cached for performance.

  ## Encrypted Fields

  Sensitive fields are encrypted using AshCloak:
  - `oidc_client_secret_encrypted` - OIDC client secret
  - `saml_private_key_encrypted` - SAML SP signing key

  ## Usage

      # Get current settings
      {:ok, settings} = AuthSettings.get_settings()

      # Check if SSO is enabled
      if settings.is_enabled and settings.mode == :active_sso do
        # Handle SSO login
      end
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak],
    authorizers: [Ash.Policy.Authorizer]

  @auth_manage_permission ServiceRadar.Identity.Constants.auth_manage_permission()
  @auth_manage_check {ServiceRadar.Policies.Checks.ActorHasPermission, permission: @auth_manage_permission}
  @settings_accept [
    :mode,
    :provider_type,
    :oidc_client_id,
    :oidc_discovery_url,
    :oidc_scopes,
    :saml_idp_metadata_url,
    :saml_idp_metadata_xml,
    :saml_sp_entity_id,
    :saml_pinned_cert_fingerprints,
    :jwt_public_key_pem,
    :jwt_jwks_url,
    :jwt_issuer,
    :jwt_audience,
    :jwt_header_name,
    :claim_mappings,
    :is_enabled,
    :allow_password_fallback
  ]

  postgres do
    table("auth_settings")
    repo(ServiceRadar.Repo)
    schema("platform")
    # Migration managed manually due to singleton constraint
    migrate?(false)
  end

  cloak do
    vault(ServiceRadar.Vault)
    attributes([:oidc_client_secret_encrypted, :saml_private_key_encrypted])
    decrypt_by_default([:oidc_client_secret_encrypted, :saml_private_key_encrypted])
  end

  code_interface do
    define(:get_singleton, action: :get_singleton)
    define(:get_settings, action: :get_singleton)
    define(:update_settings, action: :update)
    define(:update)
    define(:create)
  end

  actions do
    defaults([:read])

    create :create do
      description("Create initial auth settings")

      accept(@settings_accept)

      argument :oidc_client_secret, :string do
        sensitive?(true)
        description("OIDC client secret (will be encrypted)")
      end

      change(fn changeset, _context ->
        maybe_encrypt_secret(changeset, :oidc_client_secret, :oidc_client_secret_encrypted)
      end)
    end

    read :get_singleton do
      description("Get the singleton auth settings")
      get?(true)
      # Always returns the single row
      prepare(fn query, _ ->
        Ash.Query.limit(query, 1)
      end)
    end

    update :update do
      description("Update authentication settings")
      require_atomic?(false)

      # Virtual arguments for secrets (not stored directly)
      argument :oidc_client_secret, :string do
        sensitive?(true)
        description("OIDC client secret (will be encrypted)")
      end

      argument :saml_private_key, :string do
        sensitive?(true)
        description("SAML private key (will be encrypted)")
      end

      accept(@settings_accept)

      # Encrypt secrets before save
      change(fn changeset, _context ->
        changeset
        |> maybe_encrypt_secret(:oidc_client_secret, :oidc_client_secret_encrypted)
        |> maybe_encrypt_secret(:saml_private_key, :saml_private_key_encrypted)
      end)

      # Broadcast change for cache invalidation
      change(
        after_action(fn _changeset, result, _context ->
          Phoenix.PubSub.broadcast(
            ServiceRadar.PubSub,
            "auth_settings:changed",
            {:auth_settings_updated, result}
          )

          {:ok, result}
        end)
      )
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    read_with_permission(@auth_manage_check)

    action_with_permission([:create, :update], @auth_manage_check)
  end

  defp maybe_encrypt_secret(changeset, arg_name, encrypted_attr) do
    case Ash.Changeset.get_argument(changeset, arg_name) do
      nil ->
        changeset

      "" ->
        # Clear the encrypted value if empty string provided
        Ash.Changeset.change_attribute(changeset, encrypted_attr, nil)

      value when is_binary(value) ->
        Ash.Changeset.change_attribute(changeset, encrypted_attr, value)
    end
  end

  attributes do
    uuid_primary_key(:id)

    # Mode selection
    attribute :mode, :atom do
      allow_nil?(false)
      default(:password_only)
      public?(true)
      constraints(one_of: [:password_only, :active_sso, :passive_proxy])
      description("Authentication mode")
    end

    # Provider type (when mode = active_sso)
    attribute :provider_type, :atom do
      public?(true)
      constraints(one_of: [:oidc, :saml])
      description("SSO provider type (oidc or saml)")
    end

    # OIDC Configuration
    attribute :oidc_client_id, :string do
      public?(true)
      description("OIDC client ID")
    end

    attribute :oidc_client_secret_encrypted, :string do
      public?(false)
      sensitive?(true)
      description("Encrypted OIDC client secret")
    end

    attribute :oidc_discovery_url, :string do
      public?(true)
      description("OIDC discovery URL (.well-known/openid-configuration)")
    end

    attribute :oidc_scopes, :string do
      default("openid email profile")
      public?(true)
      description("OIDC scopes to request")
    end

    # SAML Configuration
    attribute :saml_idp_metadata_url, :string do
      public?(true)
      description("SAML IdP metadata URL")
    end

    attribute :saml_idp_metadata_xml, :string do
      public?(true)
      description("SAML IdP metadata XML (if URL not available)")
    end

    attribute :saml_sp_entity_id, :string do
      public?(true)
      description("SAML Service Provider entity ID")
    end

    attribute :saml_private_key_encrypted, :string do
      public?(false)
      sensitive?(true)
      description("Encrypted SAML SP signing key")
    end

    attribute :saml_pinned_cert_fingerprints, {:array, :string} do
      public?(true)
      default([])
      description("SHA256 fingerprints of pinned IdP certificates for additional security")
    end

    # Proxy JWT Configuration
    attribute :jwt_public_key_pem, :string do
      public?(true)
      description("JWT public key in PEM format")
    end

    attribute :jwt_jwks_url, :string do
      public?(true)
      description("JWT JWKS URL for key fetching")
    end

    attribute :jwt_issuer, :string do
      public?(true)
      description("Expected JWT issuer claim")
    end

    attribute :jwt_audience, :string do
      public?(true)
      description("Expected JWT audience claim")
    end

    attribute :jwt_header_name, :string do
      default("Authorization")
      public?(true)
      description("HTTP header containing the JWT")
    end

    # Claim mappings
    attribute :claim_mappings, :map do
      default(%{"email" => "email", "name" => "name", "sub" => "sub"})
      public?(true)
      description("Mapping from IdP claims to user attributes")
    end

    # Feature flags
    attribute :is_enabled, :boolean do
      default(false)
      allow_nil?(false)
      public?(true)
      description("Whether SSO is enabled")
    end

    attribute :allow_password_fallback, :boolean do
      default(true)
      allow_nil?(false)
      public?(true)
      description("Allow password login when SSO is enabled")
    end

    timestamps()
  end

  # Helper functions

  @doc """
  Gets the singleton auth settings.

  Returns `{:ok, settings}` or `{:error, reason}`.
  """
  def get_settings do
    get_singleton()
  end

  @doc """
  Checks if SSO is currently enabled and configured.
  """
  def sso_enabled?(%{is_enabled: true, mode: mode}) when mode in [:active_sso, :passive_proxy] do
    true
  end

  def sso_enabled?(_), do: false

  @doc """
  Returns the configured provider type, or nil if not in active_sso mode.
  """
  def get_provider_type(%{mode: :active_sso, provider_type: type}), do: type
  def get_provider_type(_), do: nil

  @doc """
  Gets the OIDC client secret (decrypted).

  Note: The secret is automatically decrypted by AshCloak.
  """
  def get_oidc_client_secret(%{oidc_client_secret_encrypted: secret}), do: secret

  @doc """
  Gets the SAML private key (decrypted).

  Note: The key is automatically decrypted by AshCloak.
  """
  def get_saml_private_key(%{saml_private_key_encrypted: key}), do: key
end
