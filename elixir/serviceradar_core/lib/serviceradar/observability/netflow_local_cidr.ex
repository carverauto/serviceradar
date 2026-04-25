defmodule ServiceRadar.Observability.NetflowLocalCidr do
  @moduledoc """
  Admin-managed local CIDR definitions for NetFlow directionality tagging.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @netflow_manage_check {ServiceRadar.Policies.Checks.ActorHasPermission,
                         permission: "settings.netflow.manage"}
  @netflow_local_cidr_fields [
    :partition,
    :label,
    :cidr,
    :enabled,
    :location_label,
    :latitude,
    :longitude
  ]

  postgres do
    table "netflow_local_cidrs"
    repo ServiceRadar.Repo

    # Managed by explicit migrations in priv/repo/migrations.
    migrate? false
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept @netflow_local_cidr_fields
    end

    update :update do
      accept @netflow_local_cidr_fields
    end

    read :list do
      primary? true
      pagination keyset?: true, default_limit: 200
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:create) do
      authorize_if @netflow_manage_check
    end

    policy action_type(:update) do
      authorize_if @netflow_manage_check
    end

    policy action_type(:destroy) do
      authorize_if @netflow_manage_check
    end

    policy action_type(:read) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :partition, :string do
      public? true
      allow_nil? true
      description "Optional partition scope (matches ocsf_network_activity.partition)"
    end

    attribute :label, :string do
      public? true
      allow_nil? true
      description "Human-readable label for this CIDR"
    end

    attribute :cidr, ServiceRadar.Types.Cidr do
      public? true
      allow_nil? false
      description "CIDR range (e.g. 10.0.0.0/8)"
    end

    attribute :enabled, :boolean do
      public? true
      allow_nil? false
      default true
    end

    attribute :location_label, :string do
      public? true
      allow_nil? true

      description "Optional physical site label used when anchoring private NetFlow endpoints on maps"
    end

    attribute :latitude, :float do
      public? true
      allow_nil? true
      constraints min: -90.0, max: 90.0
      description "Optional latitude for private endpoint map anchoring"
    end

    attribute :longitude, :float do
      public? true
      allow_nil? true
      constraints min: -180.0, max: 180.0
      description "Optional longitude for private endpoint map anchoring"
    end

    timestamps()
  end
end
