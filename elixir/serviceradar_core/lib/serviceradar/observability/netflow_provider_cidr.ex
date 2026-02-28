defmodule ServiceRadar.Observability.NetflowProviderCidr do
  @moduledoc """
  Cloud-provider CIDR entries for a specific dataset snapshot.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "netflow_provider_cidrs"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    read :by_snapshot do
      argument :snapshot_id, :uuid, allow_nil?: false
      filter expr(snapshot_id == ^arg(:snapshot_id))
    end

    create :create do
      accept [:snapshot_id, :cidr, :provider, :service, :region, :ip_version]

      upsert? true
      upsert_identity :unique_snapshot_cidr_provider

      upsert_fields [:service, :region, :ip_version]
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:read) do
      authorize_if always()
    end

    policy action([:create, :destroy]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    attribute :snapshot_id, :uuid do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :cidr, ServiceRadar.Types.Cidr do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :provider, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :service, :string do
      public? true
    end

    attribute :region, :string do
      public? true
    end

    attribute :ip_version, :string do
      public? true
    end

    create_timestamp :inserted_at
  end

  identities do
    identity :unique_snapshot_cidr_provider, [:snapshot_id, :cidr, :provider]
  end
end
