defmodule ServiceRadar.Edge.ManagedComponent do
  @moduledoc """
  Control-plane ownership and issuance generation of one managed component.

  Re-enrollment advances the generation instead of deleting revocations. An old
  certificate cannot return to service merely because the component is unblocked.
  """
  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Edge.Changes.StampCertificateActor
  alias ServiceRadar.Edge.Validations.InfrastructureNatsPermissions
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @manage_check {ActorHasPermission, permission: "settings.edge.manage"}
  @infrastructure_types [
    "core",
    "agent-gateway",
    "web-ng",
    "nats-server",
    "nats-client",
    "rperf-client",
    "datasvc",
    "zen"
  ]
  @types @infrastructure_types ++
           [
             "agent",
             "nats-leaf",
             "log-collector",
             "flow-collector",
             "bmp-collector",
             "trapd",
             "addon"
           ]

  def infrastructure_type?(type), do: type in @infrastructure_types

  postgres do
    table "managed_components"
    repo ServiceRadar.Repo
    schema "platform"
    identity_wheres_to_sql leaf_site: "component_type = 'nats-leaf'"

    references do
      reference :edge_site, on_delete: :restrict
      reference :collector, on_delete: :restrict
    end
  end

  actions do
    defaults [:read]

    create :enroll do
      accept [
        :component_id,
        :component_type,
        :partition_id,
        :host_agent_id,
        :server_hosts,
        :edge_site_id,
        :collector_id
      ]

      validate attribute_in(:component_type, @types)

      change {StampCertificateActor, attribute: :generation_started_by}

      validate present(:host_agent_id),
        where: [
          attribute_in(:component_type, [
            "agent",
            "nats-leaf",
            "log-collector",
            "flow-collector",
            "bmp-collector",
            "trapd",
            "addon"
          ])
        ]
    end

    create :adopt_infrastructure do
      accept [:component_id, :component_type, :partition_id, :server_hosts]
      argument :permissions, :map, allow_nil?: false
      validate attribute_in(:component_type, @infrastructure_types)
      validate InfrastructureNatsPermissions
      change {StampCertificateActor, attribute: :generation_started_by}
      change set_attribute(:nats_permissions, arg(:permissions))
    end

    update :set_infrastructure_permissions do
      accept []
      argument :permissions, :map, allow_nil?: false
      argument :expected_generation, :integer, allow_nil?: false, constraints: [min: 1]
      validate attribute_in(:component_type, @infrastructure_types)
      validate InfrastructureNatsPermissions
      change ServiceRadar.Edge.Changes.FenceCertificateGeneration
      change set_attribute(:nats_permissions, arg(:permissions))
    end

    update :block do
      accept []
      change set_attribute(:blocked, true)
    end

    update :reenroll do
      accept []
      change increment(:generation)

      change {StampCertificateActor, attribute: :generation_started_by}

      change set_attribute(:blocked, false)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_type_with_permission([:read, :create, :update], @manage_check)
  end

  attributes do
    attribute :component_id, :string do
      primary_key? true
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255
    end

    attribute :component_type, :string do
      allow_nil? false
      public? true
    end

    attribute :partition_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255
    end

    attribute :generation_started_by, :string, allow_nil?: false, public?: true
    attribute :server_hosts, {:array, :string}, allow_nil?: false, default: [], public?: true

    attribute :generation, :integer,
      allow_nil?: false,
      default: 1,
      public?: true,
      constraints: [min: 1]

    attribute :nats_permissions, :map, public?: true

    attribute :blocked, :boolean, allow_nil?: false, default: false, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_one :current_operation, ServiceRadar.Edge.ManagedCertificateOperation do
      source_attribute :component_id
      destination_attribute :component_id
      filter expr(status != :superseded)
    end

    belongs_to :edge_site, ServiceRadar.Edge.EdgeSite do
      public? true
    end

    belongs_to :collector, ServiceRadar.Edge.CollectorPackage do
      public? true
    end

    belongs_to :host_agent, ServiceRadar.Infrastructure.Agent do
      source_attribute :host_agent_id
      destination_attribute :uid
      attribute_type :string
      public? true
    end
  end

  identities do
    identity :host_service, [:host_agent_id, :component_type]
    identity :leaf_site, [:edge_site_id], where: expr(component_type == "nats-leaf")
    identity :collector_source, [:collector_id]
  end
end
