defmodule ServiceRadar.Identity.AdminSecretMarker do
  @moduledoc """
  Durable fingerprints of the admin bootstrap secret.

  Bootstrap records a salted password fingerprint of the admin secret it applied (or
  verified) so a later restart can tell the two drift cases apart:

  - the stored password no longer matches the secret AND the digest is
    unchanged: an operator changed the password through the UI or a reset
    flow after bootstrap applied this secret, so the operator's password
    wins and bootstrap must not touch it;
  - the stored password no longer matches the secret AND the digest moved:
    the secret rotated while the database persisted, so bootstrap resets
    the stored hash and the rotated secret re-grants login.

  Without the marker, "force sync" cannot distinguish the two and resets on
  every restart, silently reverting operator password changes.

  Only `ServiceRadarWebNG.Bootstrap.AdminUser` writes these rows. The
  fingerprint uses bcrypt over a SHA-256 prehash, so it does not expose a cheap
  verifier or depend on the endpoint signing key remaining unchanged.
  """

  use Ash.Resource,
    domain: ServiceRadar.Identity,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "admin_secret_markers"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :get_by_admin_email, action: :by_admin_email, args: [:admin_email]
    define :record, action: :record
  end

  actions do
    defaults [:read, :destroy]

    read :by_admin_email do
      argument :admin_email, :ci_string, allow_nil?: false
      get? true
      filter expr(admin_email == ^arg(:admin_email))
    end

    create :record do
      accept [:admin_email, :secret_digest]

      upsert? true
      upsert_identity :unique_admin_email
      upsert_fields [:secret_digest, :updated_at]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    attribute :admin_email, :ci_string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :secret_digest, :string do
      allow_nil? false
      public? false
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_admin_email, [:admin_email]
  end
end
