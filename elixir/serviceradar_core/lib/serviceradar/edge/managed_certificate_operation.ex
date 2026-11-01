defmodule ServiceRadar.Edge.ManagedCertificateOperation do
  @moduledoc "Durable prepare, issuance, installation and renewal state for one component rotation."
  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "managed_certificate_operations"
    repo ServiceRadar.Repo
    schema "platform"
    identity_wheres_to_sql current_component: "status != 'superseded'"

    custom_indexes do
      index [:status, :renew_after]
    end
  end

  actions do
    defaults [:read]

    read :reconcile do
      pagination keyset?: true, required?: false, default_limit: 100
    end

    create :begin do
      accept [
        :component_id,
        :generation,
        :host_agent_id,
        :partition_id,
        :service,
        :server_hosts,
        :requested_by
      ]
    end

    update :progress do
      accept [
        :status,
        :csrs,
        :certificates,
        :fingerprints,
        :renew_after,
        :receipt,
        :error,
        :observed_roles
      ]
    end

    update :supersede do
      accept []
      change set_attribute(:status, :superseded)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    read_with_permission(
      {ServiceRadar.Policies.Checks.ActorHasPermission, permission: "settings.edge.manage"}
    )
  end

  attributes do
    uuid_primary_key :id
    attribute :install_command_id, :uuid, allow_nil?: false, default: &Ash.UUID.generate/0
    attribute :generation, :integer, allow_nil?: false, constraints: [min: 1], public?: true
    attribute :host_agent_id, :string, allow_nil?: false, public?: true
    attribute :partition_id, :string, allow_nil?: false, public?: true
    attribute :service, :string, allow_nil?: false, public?: true
    attribute :server_hosts, {:array, :string}, allow_nil?: false, default: []

    attribute :status, :atom,
      allow_nil?: false,
      default: :preparing,
      public?: true,
      constraints: [one_of: [:preparing, :issuing, :installing, :activated, :failed, :superseded]]

    attribute :csrs, :map, allow_nil?: false, default: %{}
    attribute :certificates, :map, allow_nil?: false, default: %{}
    attribute :fingerprints, :map, allow_nil?: false, default: %{}, public?: true
    attribute :receipt, :map, allow_nil?: false, default: %{}, public?: true
    attribute :observed_roles, :map, allow_nil?: false, default: %{}, public?: true
    attribute :renew_after, :utc_datetime_usec, public?: true
    attribute :error, :string, public?: true
    attribute :requested_by, :string, allow_nil?: false, public?: true
    timestamps()
  end

  relationships do
    belongs_to :component, ServiceRadar.Edge.ManagedComponent do
      source_attribute :component_id
      destination_attribute :component_id
      attribute_type :string
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :current_component, [:component_id], where: expr(status != :superseded)
  end
end
