defmodule ServiceRadar.Edge.EdgeSite do
  @moduledoc """
  Represents a customer's edge deployment location where NATS leaf servers and collectors run.

  An EdgeSite is a physical or logical location in the customer's network where:
  - A NATS leaf server provides local message buffering and WAN resilience
  - Collectors connect to the local NATS leaf instead of the SaaS cluster
  - Messages are forwarded upstream to the SaaS NATS cluster via leaf protocol

  ## Use Cases

  - **Data centers**: Deploy a leaf per DC for low-latency local collection
  - **Remote offices**: Handle WAN outages gracefully with local buffering
  - **Compliance**: Route data through customer-controlled infrastructure first
  - **Network simplicity**: Single outbound connection (leaf -> SaaS) vs many collector connections

  ## State Machine

  - `pending` - Site created, waiting for provisioning
  - `active` - NATS leaf is connected and operational
  - `offline` - NATS leaf has disconnected

  ## Example

      # Create a new edge site
      EdgeSite
      |> Ash.Changeset.for_create(:create, %{
        name: "NYC Office",
        slug: "nyc-office",
        nats_leaf_url: "nats://10.0.1.50:4222"
      })
      |> Ash.create()
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine]

  postgres do
    table "edge_sites"
    repo ServiceRadar.Repo
  end

  state_machine do
    initial_states [:pending]
    default_initial_state :pending
    state_attribute :status

    transitions do
      transition :activate, from: :pending, to: :active
      transition :go_offline, from: :active, to: :offline
      transition :come_online, from: :offline, to: :active
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? true
  end

  actions do
    defaults [:read, :destroy]

    read :by_slug do
      description "Find edge site by tenant and slug"
      argument :slug, :string, allow_nil?: false
      get? true
      filter expr(slug == ^arg(:slug))
    end

    read :active do
      description "Get active (non-deleted) edge sites"
      filter expr(status != :deleted)
    end

    create :create do
      description "Create a new edge site"
      accept [:name, :slug, :nats_leaf_url]

      # Validate and normalize slug
      change fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :slug) do
          nil ->
            # Generate slug from name
            name = Ash.Changeset.get_attribute(changeset, :name) || ""

            slug =
              name
              |> String.downcase()
              |> String.replace(~r/[^a-z0-9\-]/, "-")
              |> String.replace(~r/-+/, "-")
              |> String.trim("-")

            Ash.Changeset.change_attribute(changeset, :slug, slug)

          slug ->
            # Validate provided slug
            if Regex.match?(~r/^[a-z0-9][a-z0-9\-]*[a-z0-9]$|^[a-z0-9]$/, slug) do
              changeset
            else
              Ash.Changeset.add_error(changeset, :slug, "must be lowercase alphanumeric with dashes")
            end
        end
      end

      # Trigger NATS leaf provisioning after creation
      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, site ->
          # Create NatsLeafServer and trigger provisioning
          case create_nats_leaf_server(site) do
            {:ok, _leaf_server} -> {:ok, site}
            {:error, reason} -> {:error, reason}
          end
        end)
      end
    end

    update :update do
      description "Update edge site details"
      accept [:name, :nats_leaf_url]
    end

    update :activate do
      description "Mark site as active (leaf connected)"
      accept []
    end

    update :go_offline do
      description "Mark site as offline (leaf disconnected)"
      accept []
    end

    update :come_online do
      description "Mark site as back online"
      accept []
    end

    update :touch do
      description "Update last_seen_at timestamp"
      accept []
      require_atomic? false

      change set_attribute(:last_seen_at, &DateTime.utc_now/0)
    end
  end

  policies do
    # Super admins can manage all sites
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # Tenant admins can manage their tenant's sites
    policy action_type(:read) do
      authorize_if expr(tenant_id == ^actor(:tenant_id))
    end

    policy action_type(:create) do
      authorize_if expr(^actor(:role) == :admin and tenant_id == ^actor(:tenant_id))
    end

    policy action_type(:update) do
      authorize_if expr(^actor(:role) == :admin and tenant_id == ^actor(:tenant_id))
    end

    policy action_type(:destroy) do
      authorize_if expr(^actor(:role) == :admin and tenant_id == ^actor(:tenant_id))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
      description "Tenant this edge site belongs to"
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Human-readable site name (e.g., 'NYC Office', 'Factory Floor 3')"
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
      description "URL-safe identifier (e.g., 'nyc-office', 'factory-3')"
    end

    attribute :status, :atom do
      allow_nil? false
      default :pending
      public? true
      constraints one_of: [:pending, :active, :offline]
      description "Current operational status"
    end

    attribute :nats_leaf_url, :string do
      allow_nil? true
      public? true
      description "Local NATS URL for collectors (e.g., 'nats://10.0.1.50:4222')"
    end

    attribute :last_seen_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "Last time the NATS leaf connected or sent data"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :tenant, ServiceRadar.Identity.Tenant do
      source_attribute :tenant_id
      allow_nil? false
    end

    has_one :nats_leaf_server, ServiceRadar.Edge.NatsLeafServer do
      source_attribute :id
      destination_attribute :edge_site_id
    end

    has_many :collector_packages, ServiceRadar.Edge.CollectorPackage do
      source_attribute :id
      destination_attribute :edge_site_id
    end
  end

  identities do
    identity :unique_slug_per_tenant, [:tenant_id, :slug]
  end

  # Helper function to create associated NatsLeafServer
  defp create_nats_leaf_server(site) do
    # Get platform NATS URL from config
    upstream_url = Application.get_env(:serviceradar, :nats_leaf_upstream_url, "tls://nats.serviceradar.cloud:7422")

    ServiceRadar.Edge.NatsLeafServer
    |> Ash.Changeset.for_create(:create, %{
      edge_site_id: site.id,
      tenant_id: site.tenant_id,
      upstream_url: upstream_url,
      local_listen: "0.0.0.0:4222"
    })
    |> Ash.create(authorize?: false)
  end
end
