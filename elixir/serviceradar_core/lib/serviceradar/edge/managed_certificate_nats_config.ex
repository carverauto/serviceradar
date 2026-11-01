defmodule ServiceRadar.Edge.ManagedCertificateNatsConfig do
  @moduledoc """
  Deployment-internal NATS authentication keys for managed certificate enforcement.

  Only system actors may read or write this record. The bootstrap API returns a
  public configuration projection after authorizing the operator; seeds are never
  part of that response. Decryption is explicit for the core authentication worker.
  """
  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshCloak],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "managed_certificate_nats_config"
    repo ServiceRadar.Repo
    schema "platform"

    check_constraints do
      check_constraint :id, "managed_certificate_nats_config_singleton", check: "id = 'default'"
    end
  end

  cloak do
    vault(ServiceRadar.Vault)
    attributes([:issuer_seed, :auth_seed, :system_seed])
    decrypt_by_default([])
  end

  actions do
    defaults [:read]

    create :configure do
      accept [
        :auth_mode,
        :account_name,
        :issuer_nkey,
        :auth_nkey,
        :system_nkey,
        :issuer_seed,
        :auth_seed,
        :system_seed
      ]

      validate attribute_in(:auth_mode, ["static_mtls", "operator_jwt"])
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    attribute :id, :string, primary_key?: true, allow_nil?: false, default: "default"
    attribute :auth_mode, :string, allow_nil?: false, default: "static_mtls", public?: true
    attribute :account_name, :string, allow_nil?: false, public?: true
    attribute :issuer_nkey, :string, allow_nil?: false, public?: true
    attribute :auth_nkey, :string, allow_nil?: false, public?: true
    attribute :system_nkey, :string, allow_nil?: false, public?: true
    attribute :issuer_seed, :string, allow_nil?: false, sensitive?: true
    attribute :auth_seed, :string, allow_nil?: false, sensitive?: true
    attribute :system_seed, :string, allow_nil?: false, sensitive?: true
    create_timestamp :inserted_at
  end
end
