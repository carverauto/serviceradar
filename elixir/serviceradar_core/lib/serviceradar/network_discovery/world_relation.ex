defmodule ServiceRadar.NetworkDiscovery.WorldRelation do
  @moduledoc "Canonical relation identity bound to positions in one topology coordinate system."

  use Ash.Resource,
    domain: ServiceRadar.NetworkDiscovery,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.NetworkDiscovery.WorldPosition

  postgres do
    table "topology_world_relations"
    schema "platform"
    repo ServiceRadar.Repo

    references do
      reference :source, match_with: [layout_version: :layout_version]
      reference :target, match_with: [layout_version: :layout_version]
    end

    custom_indexes do
      index [:layout_version, :source_id],
        where: "active",
        name: "topology_world_relations_source_idx"

      index [:layout_version, :target_id],
        where: "active",
        name: "topology_world_relations_target_idx"
    end

    check_constraints do
      check_constraint :source_if_index, "topology_world_relations_interface_indices",
        check:
          "(source_if_index IS NULL OR source_if_index > 0) AND (target_if_index IS NULL OR target_if_index > 0)"
    end
  end

  actions do
    read :read do
      primary? true
      pagination keyset?: true, required?: false, default_limit: 500, max_page_size: 500
    end

    create :upsert do
      accept [
        :layout_version,
        :relation_id,
        :source_id,
        :target_id,
        :evidence_class,
        :role,
        :source_if_index,
        :source_if_name,
        :target_if_index,
        :target_if_name,
        :active
      ]

      upsert? true

      upsert_fields [
        :source_id,
        :target_id,
        :evidence_class,
        :role,
        :source_if_index,
        :source_if_name,
        :target_if_index,
        :target_if_name,
        :active,
        :updated_at
      ]
    end

    update :set_active do
      accept [:active]
    end

    destroy :discard
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    read_with_permission(
      {ServiceRadar.Policies.Checks.ActorHasPermission, permission: "devices.view"}
    )
  end

  attributes do
    attribute :layout_version, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :relation_id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :source_id, :string, allow_nil?: false, public?: true
    attribute :target_id, :string, allow_nil?: false, public?: true
    attribute :evidence_class, :string, allow_nil?: false, public?: true
    attribute :role, :string, public?: true
    attribute :source_if_index, :integer, public?: true, constraints: [min: 1]
    attribute :source_if_name, :string, public?: true
    attribute :target_if_index, :integer, public?: true, constraints: [min: 1]
    attribute :target_if_name, :string, public?: true
    attribute :active, :boolean, allow_nil?: false, default: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :layout, ServiceRadar.NetworkDiscovery.WorldLayout do
      source_attribute :layout_version
      destination_attribute :layout_version
      define_attribute? false
      allow_nil? false
    end

    belongs_to :source, WorldPosition do
      source_attribute :source_id
      destination_attribute :device_id
      define_attribute? false
      allow_nil? false
    end

    belongs_to :target, WorldPosition do
      source_attribute :target_id
      destination_attribute :device_id
      define_attribute? false
      allow_nil? false
    end
  end
end
