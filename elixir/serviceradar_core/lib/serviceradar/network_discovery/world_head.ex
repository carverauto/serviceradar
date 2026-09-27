defmodule ServiceRadar.NetworkDiscovery.WorldHead do
  @moduledoc "The publication pointer shared by topology world readers and writers."

  use Ash.Resource,
    domain: ServiceRadar.NetworkDiscovery,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("topology_world_head")
    schema("platform")
    repo(ServiceRadar.Repo)

    check_constraints do
      check_constraint(:id, "topology_world_head_singleton", check: "id = 'global' AND generation >= 0")
    end
  end

  actions do
    defaults([:read])

    create :initialize do
      accept([])
      upsert?(true)
      upsert_fields([])
    end

    update :publish do
      accept([:active_layout_version, :generation])
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission({ServiceRadar.Policies.Checks.ActorHasPermission, permission: "analytics.view"})
  end

  attributes do
    attribute(:id, :string, primary_key?: true, allow_nil?: false, default: "global")
    attribute(:active_layout_version, :uuid, public?: true)
    attribute(:generation, :integer, allow_nil?: false, default: 0, public?: true, constraints: [min: 0])
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :active_layout, ServiceRadar.NetworkDiscovery.WorldLayout do
      source_attribute(:active_layout_version)
      destination_attribute(:layout_version)
      define_attribute?(false)
    end
  end
end
