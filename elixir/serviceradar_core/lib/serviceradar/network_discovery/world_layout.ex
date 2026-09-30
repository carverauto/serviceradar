defmodule ServiceRadar.NetworkDiscovery.WorldLayout do
  @moduledoc "A coordinate system staged before activation and retained across incremental publications."

  use Ash.Resource,
    domain: ServiceRadar.NetworkDiscovery,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  postgres do
    table "topology_world_layouts"
    schema "platform"
    repo ServiceRadar.Repo

    check_constraints do
      check_constraint :extent, "topology_world_layout_bounds",
        check:
          "extent = 16777216 AND zmax BETWEEN 0 AND 24 AND node_count >= 0 AND relation_count >= 0"

      check_constraint :status, "topology_world_layout_status",
        check: "status IN ('building', 'active', 'retired')"
    end
  end

  actions do
    defaults [:read]

    create :stage do
      accept [:algorithm_version, :zmax, :source_digest, :node_count, :relation_count, :pipeline_stats]
    end

    create :initialize_stage do
      accept [
        :algorithm_version,
        :zmax,
        :source_digest,
        :node_count,
        :relation_count,
        :pipeline_stats
      ]
      argument :layout_version, :uuid, allow_nil?: false
      change set_attribute(:layout_version, arg(:layout_version))
      upsert? true
      upsert_fields []
    end

    update :publish do
      accept [
        :status,
        :algorithm_version,
        :zmax,
        :source_digest,
        :node_count,
        :relation_count,
        :pipeline_stats
      ]
    end

    destroy :discard
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission({ActorHasPermission, permission: "analytics.view"})

    action_with_permission(:stage, {
      ActorHasPermission,
      permission: "settings.networks.manage"
    })
  end

  attributes do
    uuid_primary_key :layout_version
    attribute :extent, :integer, allow_nil?: false, default: 16_777_216, public?: true

    attribute :algorithm_version, :string,
      allow_nil?: false,
      default: "hierarchical-morton-v1",
      public?: true

    attribute :zmax, :integer,
      allow_nil?: false,
      default: 16,
      public?: true,
      constraints: [min: 0, max: 24]

    attribute :status, :atom do
      allow_nil? false
      default :building
      public? true
      constraints one_of: [:building, :active, :retired]
    end

    attribute :source_digest, :string, allow_nil?: false, public?: true
    attribute :node_count, :integer, allow_nil?: false, public?: true, constraints: [min: 0]
    attribute :relation_count, :integer, allow_nil?: false, public?: true, constraints: [min: 0]
    attribute :pipeline_stats, :map, allow_nil?: false, default: %{}, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
