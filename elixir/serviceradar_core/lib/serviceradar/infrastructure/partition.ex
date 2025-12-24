defmodule ServiceRadar.Infrastructure.Partition do
  @moduledoc """
  Partition resource for managing network partitions.

  Partitions enable monitoring of overlapping IP address spaces by providing
  logical separation. Each partition can have its own CIDR ranges and pollers,
  allowing the same IP address to exist in multiple partitions without conflict.

  ## Use Cases

  - Multi-site deployments with overlapping RFC1918 addresses
  - VPN/VPC separation
  - Customer network isolation in MSP scenarios
  - Lab/production separation with same IP ranges
  """

  use Ash.Resource,
    domain: ServiceRadar.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "partitions"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? true
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Partition display name"
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
      description "URL-friendly identifier"
    end

    attribute :description, :string do
      public? true
      description "Partition description"
    end

    attribute :enabled, :boolean do
      default true
      public? true
      description "Whether this partition is active"
    end

    # Network configuration
    attribute :cidr_ranges, {:array, :string} do
      default []
      public? true
      description "CIDR ranges covered by this partition"
    end

    attribute :default_gateway, :string do
      public? true
      description "Default gateway for this partition"
    end

    attribute :dns_servers, {:array, :string} do
      default []
      public? true
      description "DNS servers for this partition"
    end

    # Location/site information
    attribute :site, :string do
      public? true
      description "Physical site or location name"
    end

    attribute :region, :string do
      public? true
      description "Geographic region"
    end

    attribute :environment, :string do
      default "production"
      public? true
      description "Environment type (production, staging, development, lab)"
    end

    # Connectivity
    attribute :connectivity_type, :string do
      default "direct"
      public? true
      description "How this partition is accessed (direct, vpn, proxy)"
    end

    attribute :proxy_endpoint, :string do
      public? true
      description "Proxy endpoint if connectivity_type is proxy"
    end

    # Metadata
    attribute :metadata, :map do
      default %{}
      public? true
      description "Additional metadata"
    end

    attribute :created_at, :utc_datetime do
      public? true
      description "When partition was created"
    end

    attribute :updated_at, :utc_datetime do
      public? true
      description "When partition was last updated"
    end

    # Multi-tenancy
    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
      description "Tenant this partition belongs to"
    end
  end

  identities do
    identity :unique_slug_per_tenant, [:tenant_id, :slug]
  end

  relationships do
    has_many :pollers, ServiceRadar.Infrastructure.Poller do
      public? true
      description "Pollers assigned to this partition"
    end
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_slug do
      argument :slug, :string, allow_nil?: false
      get? true
      filter expr(slug == ^arg(:slug))
    end

    read :enabled do
      description "All enabled partitions"
      filter expr(enabled == true)
    end

    read :by_site do
      argument :site, :string, allow_nil?: false
      filter expr(site == ^arg(:site))
    end

    read :by_environment do
      argument :environment, :string, allow_nil?: false
      filter expr(environment == ^arg(:environment))
    end

    create :create do
      accept [
        :name, :slug, :description, :enabled,
        :cidr_ranges, :default_gateway, :dns_servers,
        :site, :region, :environment,
        :connectivity_type, :proxy_endpoint, :metadata
      ]

      change fn changeset, _context ->
        now = DateTime.utc_now()

        changeset
        |> Ash.Changeset.change_attribute(:created_at, now)
        |> Ash.Changeset.change_attribute(:updated_at, now)
      end
    end

    update :update do
      accept [
        :name, :description, :enabled,
        :cidr_ranges, :default_gateway, :dns_servers,
        :site, :region, :environment,
        :connectivity_type, :proxy_endpoint, :metadata
      ]

      change set_attribute(:updated_at, &DateTime.utc_now/0)
    end

    update :enable do
      description "Enable the partition"
      change set_attribute(:enabled, true)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
    end

    update :disable do
      description "Disable the partition"
      change set_attribute(:enabled, false)
      change set_attribute(:updated_at, &DateTime.utc_now/0)
    end
  end

  calculations do
    calculate :display_name, :string, expr(
      if not is_nil(name) do
        name
      else
        slug
      end
    )

    calculate :cidr_count, :integer, expr(
      fragment("coalesce(array_length(?, 1), 0)", cidr_ranges)
    )

    calculate :environment_label, :string, expr(
      cond do
        environment == "production" -> "Production"
        environment == "staging" -> "Staging"
        environment == "development" -> "Development"
        environment == "lab" -> "Lab"
        true -> environment
      end
    )

    calculate :status_color, :string, expr(
      cond do
        enabled == true -> "green"
        true -> "gray"
      end
    )
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_slug, action: :by_slug, args: [:slug]
    define :list_enabled, action: :enabled
  end

  policies do
    # Super admins bypass all policies
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # All authenticated users can read partitions
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :viewer)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Only admins can create partitions
    policy action(:create) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    # Only admins can update/enable/disable partitions
    policy action([:update, :enable, :disable]) do
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end
end
