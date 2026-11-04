defmodule ServiceRadar.Edge.EdgeIssuerKeyRecord do
  @moduledoc """
  The stored edge issuer key (`ServiceRadar.Edge.IssuerKey`): one row, `id = 'default'`.

  The Ed25519 public key is plaintext. The 32-byte seed is encrypted at rest by AshCloak and
  decrypted only when core loads it, by the system actor. Core generates the row on first use
  and the create is insert-only, so concurrent replicas converge on one key and a restart
  never changes it. The key travels with a database backup, so a restore with the original
  cloak key keeps every outstanding capability verifiable. Modeled on
  `ServiceRadar.Edge.ManagedCertificatePolicyKey`.
  """
  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "edge_issuer_key"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  cloak do
    vault(ServiceRadar.Vault)
    attributes([:seed])
    decrypt_by_default([])
  end

  actions do
    defaults [:read]

    create :generate do
      description "Store a generated key; a key that already exists is kept"
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
