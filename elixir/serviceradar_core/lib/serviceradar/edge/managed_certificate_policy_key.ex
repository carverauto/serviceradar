defmodule ServiceRadar.Edge.ManagedCertificatePolicyKey do
  @moduledoc """
  Dedicated deployment root for signed certificate-policy snapshots.

  The seed is encrypted at rest and decrypted only by core. Repeated bootstrap is
  insert-only: an existing pinned public key must never change on process restart.
  """
  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "managed_certificate_policy_key"
    repo ServiceRadar.Repo
    schema "platform"

    check_constraints do
      check_constraint :id, "managed_certificate_policy_key_singleton", check: "id = 'default'"
    end
  end

  cloak do
    vault(ServiceRadar.Vault)
    attributes([:seed])
    decrypt_by_default([])
  end

  actions do
    defaults [:read]

    create :configure do
      accept [:public_key, :seed]
      upsert? true
      upsert_fields []
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, default: "default"

    attribute :public_key, :string,
      allow_nil?: false,
      public?: true,
      constraints: [match: ~r/\A[A-Za-z0-9+\/]{43}=\z/]

    attribute :seed, :string,
      allow_nil?: false,
      sensitive?: true,
      constraints: [match: ~r/\A[A-Za-z0-9+\/]{43}=\z/]

    create_timestamp :inserted_at
  end
end
