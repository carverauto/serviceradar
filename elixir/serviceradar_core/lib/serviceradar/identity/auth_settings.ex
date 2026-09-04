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
  @auth_manage_check {ServiceRadar.Policies.Checks.ActorHasPermission,
                      permission: @auth_manage_permission}
  @settings_accept [
    :mode,
    :provider_type,
    :oidc_client_id,
    :oidc_discovery_url,
    :oidc_scopes,
    :oidc_pkce_mode,
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
    :allow_password_fallback,
    :sso_auto_provision
  ]

  postgres do
    table "auth_settings"
    repo ServiceRadar.Repo
    schema "platform"
    # Migration managed manually due to singleton constraint
    migrate? false
  end

  cloak do
    vault(ServiceRadar.Vault)
    attributes([:oidc_client_secret_encrypted, :saml_private_key_encrypted])
    decrypt_by_default([:oidc_client_secret_encrypted, :saml_private_key_encrypted])
  end

  code_interface do
    define :get_singleton, action: :get_singleton
    define :get_settings, action: :get_singleton
    define :update_settings, action: :update
    define :update
    define :create
  end

  actions do
    defaults [:read]

    create :create do
      description "Create initial auth settings"

      accept @settings_accept

      argument :oidc_client_secret, :string do
        sensitive? true
        # Keep secrets verbatim and allow an explicit "" to clear the stored value;
        # the Ash string defaults (trim?: true, allow_empty?: false) would otherwise
        # coerce "" -> nil and silently drop the clear request.
        constraints allow_empty?: true, trim?: false
        description "OIDC client secret (will be encrypted)"
      end

      change fn changeset, _context ->
        maybe_encrypt_secret(changeset, :oidc_client_secret, :oidc_client_secret_encrypted)
      end

      change after_action(&broadcast_cache_update/3)

      validate fn changeset, _context ->
        validate_passive_proxy_verification_material(changeset)
      end
    end

    read :get_singleton do
      description "Get the singleton auth settings"
      get? true
      # Always returns the single row
      prepare fn query, _ ->
        Ash.Query.limit(query, 1)
      end
    end

    update :update do
      description "Update authentication settings"
      require_atomic? false

      # Virtual arguments for secrets (not stored directly)
      argument :oidc_client_secret, :string do
        sensitive? true
        # Keep secrets verbatim and allow an explicit "" to clear the stored value;
        # the Ash string defaults (trim?: true, allow_empty?: false) would otherwise
        # coerce "" -> nil and silently drop the clear request.
        constraints allow_empty?: true, trim?: false
        description "OIDC client secret (will be encrypted)"
      end

      argument :saml_private_key, :string do
        sensitive? true
        # See :oidc_client_secret above: preserve the key verbatim and allow ""
        # to clear it instead of being coerced to nil by the Ash string defaults.
        constraints allow_empty?: true, trim?: false
        description "SAML private key (will be encrypted)"
      end

      accept @settings_accept

      # Encrypt secrets before save
      change fn changeset, _context ->
        changeset
        |> maybe_encrypt_secret(:oidc_client_secret, :oidc_client_secret_encrypted)
        |> maybe_encrypt_secret(:saml_private_key, :saml_private_key_encrypted)
      end

      change after_action(&broadcast_cache_update/3)

      validate fn changeset, _context ->
        validate_passive_proxy_verification_material(changeset)
      end
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    read_with_permission(@auth_manage_check)

    action_with_permission([:create, :update], @auth_manage_check)
  end

  defp broadcast_cache_update(_changeset, result, _context) do
    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "auth_settings:changed",
      {:auth_settings_updated, result}
    )

    {:ok, result}
  end

  defp maybe_encrypt_secret(changeset, arg_name, encrypted_attr) do
    case Ash.Changeset.get_argument(changeset, arg_name) do
      nil ->
        changeset

      "" ->
        # Clear the encrypted value if an empty string is provided. AshCloak
        # rewrites `encrypted_attr` into a decrypt calculation and stores the
        # ciphertext in the underlying `encrypted_<attr>` column, so null that
        # storage column directly rather than the (read-only) calculation.
        storage_attr = String.to_existing_atom("encrypted_#{encrypted_attr}")
        Ash.Changeset.force_change_attribute(changeset, storage_attr, nil)

      value when is_binary(value) ->
        # `encrypted_attr` is no longer a plain attribute: AshCloak turned it into
        # a decrypt calculation backed by the `encrypted_<attr>` storage column, so
        # `change_attribute/3` on it raises NoSuchAttribute. Use AshCloak's helper
        # to encrypt the plaintext and write the ciphertext to the storage column;
        # the decrypt calculation then round-trips it back to plaintext on read.
        AshCloak.encrypt_and_set(changeset, encrypted_attr, value)
    end
  end

  defp validate_passive_proxy_verification_material(changeset) do
    enabled? = Ash.Changeset.get_attribute(changeset, :is_enabled)
    mode = Ash.Changeset.get_attribute(changeset, :mode)
    jwks_url = Ash.Changeset.get_attribute(changeset, :jwt_jwks_url)
    public_key_pem = Ash.Changeset.get_attribute(changeset, :jwt_public_key_pem)

    if enabled? == true and mode == :passive_proxy and blank?(jwks_url) and blank?(public_key_pem) do
      {:error,
       field: :jwt_jwks_url,
       message: "passive proxy authentication requires a JWKS URL or public key PEM"}
    else
      :ok
    end
  end

  defp blank?(value), do: is_nil(value) or (is_binary(value) and String.trim(value) == "")

  attributes do
    uuid_primary_key :id

    # Mode selection
    attribute :mode, :atom do
      allow_nil? false
      default :password_only
      public? true
      constraints one_of: [:password_only, :active_sso, :passive_proxy]
      description "Authentication mode"
    end

    # Provider type (when mode = active_sso)
    attribute :provider_type, :atom do
      public? true
      constraints one_of: [:oidc, :saml]
      description "SSO provider type (oidc or saml)"
    end

    # OIDC Configuration
    attribute :oidc_client_id, :string do
      public? true
      description "OIDC client ID"
    end

    attribute :oidc_client_secret_encrypted, :string do
      public? false
      sensitive? true
      description "Encrypted OIDC client secret"
    end

    attribute :oidc_discovery_url, :string do
      public? true
      description "OIDC discovery URL (.well-known/openid-configuration)"
    end

    attribute :oidc_scopes, :string do
      default "openid email profile"
      public? true
      description "OIDC scopes to request. Include offline_access for MCP refresh."
    end

    attribute :oidc_pkce_mode, :atom do
      allow_nil? false
      default :auto
      public? true
      constraints one_of: [:auto, :required, :disabled]

      description """
      Upstream OIDC PKCE (RFC 7636 S256) for the confidential-client login.
      auto: send S256 when advertised or when discovery omits methods.
      required: always send S256; refuse login if methods omit S256.
      disabled: never send PKCE (escape hatch for a provider that rejects code_verifier).
      Never falls back to plain.
      """
    end

    # SAML Configuration
    attribute :saml_idp_metadata_url, :string do
      public? true
      description "SAML IdP metadata URL"
    end

    attribute :saml_idp_metadata_xml, :string do
      public? true
      description "SAML IdP metadata XML (if URL not available)"
    end

    attribute :saml_sp_entity_id, :string do
      public? true
      description "SAML Service Provider entity ID"
    end

    attribute :saml_private_key_encrypted, :string do
      public? false
      sensitive? true
      description "Encrypted SAML SP signing key"
    end

    attribute :saml_pinned_cert_fingerprints, {:array, :string} do
      public? true
      default []
      description "SHA256 fingerprints of pinned IdP certificates for additional security"
    end

    # Proxy JWT Configuration
    attribute :jwt_public_key_pem, :string do
      public? true
      description "JWT public key in PEM format"
    end

    attribute :jwt_jwks_url, :string do
      public? true
      description "JWT JWKS URL for key fetching"
    end

    attribute :jwt_issuer, :string do
      public? true
      description "Expected JWT issuer claim"
    end

    attribute :jwt_audience, :string do
      public? true
      description "Expected JWT audience claim"
    end

    attribute :jwt_header_name, :string do
      default "Authorization"
      public? true
      description "HTTP header containing the JWT"
    end

    # Claim mappings
    attribute :claim_mappings, :map do
      default %{"email" => "email", "name" => "name", "sub" => "sub"}
      public? true
      description "Mapping from IdP claims to user attributes"
    end

    # Feature flags
    attribute :is_enabled, :boolean do
      default false
      allow_nil? false
      public? true
      description "Whether SSO is enabled"
    end

    attribute :allow_password_fallback, :boolean do
      default true
      allow_nil? false
      public? true
      description "Allow password login when SSO is enabled"
    end

    # Just-in-time provisioning. Defaults to false (deny): an SSO identity with no
    # pre-existing local account is rejected rather than auto-created. Admins must
    # explicitly opt in to auto-create accounts on first SSO login.
    attribute :sso_auto_provision, :boolean do
      default false
      allow_nil? false
      public? true
      description "Auto-create a local account on first SSO login when no account exists"
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
