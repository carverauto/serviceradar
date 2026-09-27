defmodule ServiceRadar.NetworkDiscovery.WorldPosition do
  @moduledoc "Persistent integer world coordinates; retiring a device preserves its placement."

  use Ash.Resource,
    domain: ServiceRadar.NetworkDiscovery,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("topology_world_positions")
    schema("platform")
    repo(ServiceRadar.Repo)

    custom_indexes do
      index([:layout_version], where: "active", name: "topology_world_positions_active_idx")
    end

    check_constraints do
      check_constraint(:label, "topology_world_positions_label", check: "octet_length(label) <= 256")

      check_constraint(:x, "topology_world_positions_grid",
        check:
          "x BETWEEN 0 AND 16777215 AND y BETWEEN 0 AND 16777215 AND min_zoom BETWEEN 0 AND 24 AND placement_depth BETWEEN 0 AND 24"
      )

      check_constraint(:component_z, "topology_world_positions_component",
        check:
          "component_z BETWEEN 0 AND 24 AND component_x >= 0 AND component_y >= 0 AND component_x < (1::bigint << component_z::integer) AND component_y < (1::bigint << component_z::integer)"
      )
    end
  end

  actions do
    read :read do
      primary?(true)
      pagination(keyset?: true, required?: false, default_limit: 500, max_page_size: 500)
    end

    create :insert do
      accept([
        :layout_version,
        :device_id,
        :label,
        :x,
        :y,
        :min_zoom,
        :parent_id,
        :component_id,
        :component_z,
        :component_x,
        :component_y,
        :placement_depth,
        :active
      ])
    end

    update :set_active do
      accept([:active])
    end

    update :update_display do
      accept([:label, :min_zoom])
    end

    destroy(:discard)
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission({ServiceRadar.Policies.Checks.ActorHasPermission, permission: "devices.view"})
  end

  attributes do
    attribute(:layout_version, :uuid, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:device_id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:label, :string, allow_nil?: false, public?: true, constraints: [max_length: 256])
    attribute(:x, :integer, allow_nil?: false, public?: true, constraints: [min: 0, max: 16_777_215])
    attribute(:y, :integer, allow_nil?: false, public?: true, constraints: [min: 0, max: 16_777_215])
    attribute(:min_zoom, :integer, allow_nil?: false, public?: true, constraints: [min: 0, max: 24])
    attribute(:parent_id, :string, public?: true)
    attribute(:component_id, :string, allow_nil?: false, public?: true)
    attribute(:component_z, :integer, allow_nil?: false, public?: true, constraints: [min: 0, max: 24])
    attribute(:component_x, :integer, allow_nil?: false, public?: true, constraints: [min: 0, max: 16_777_215])
    attribute(:component_y, :integer, allow_nil?: false, public?: true, constraints: [min: 0, max: 16_777_215])
    attribute(:placement_depth, :integer, allow_nil?: false, public?: true, constraints: [min: 0, max: 24])
    attribute(:active, :boolean, allow_nil?: false, default: true, public?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :layout, ServiceRadar.NetworkDiscovery.WorldLayout do
      source_attribute(:layout_version)
      destination_attribute(:layout_version)
      define_attribute?(false)
      allow_nil?(false)
    end
  end
end
