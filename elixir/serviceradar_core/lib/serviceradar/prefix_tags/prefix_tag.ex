defmodule ServiceRadar.PrefixTags.PrefixTag do
  @moduledoc """
  A single IP/CIDR prefix and its associated tags within a snapshot.

  Manual entries live under the permanent `manual` snapshot source and support
  create/update/destroy. Imported snapshot rows are read-only for operators.
  """

  use Ash.Resource,
    domain: ServiceRadar.PrefixTags,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Types.Cidr
  alias ServiceRadar.Types.Jsonb

  @manage_check {ServiceRadar.Policies.Checks.ActorHasPermission,
                 permission: "settings.prefix_tags.manage"}

  @prefix_tag_fields [
    :snapshot_id,
    :prefix,
    :vrf,
    :tags,
    :site,
    :role,
    :tenant,
    :status,
    :partition
  ]

  postgres do
    table "prefix_tags"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  code_interface do
    define :create, action: :create
    define :create_manual, action: :create_manual
    define :update, action: :update
    define :destroy, action: :destroy
    define :by_snapshot, action: :by_snapshot
    define :list_active, action: :list_active
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept @prefix_tag_fields
    end

    create :create_manual do
      description "Create a manual prefix tag under the active manual snapshot"
      accept @prefix_tag_fields
      # Callers ensure the manual snapshot exists and pass its id; the importer
      # and engine use :create for bulk snapshot loads.
    end

    update :update do
      accept [:prefix, :vrf, :tags, :site, :role, :tenant, :status, :partition]
    end

    read :by_snapshot do
      argument :snapshot_id, :uuid, allow_nil?: false
      filter expr(snapshot_id == ^arg(:snapshot_id))
      pagination keyset?: true, default_limit: 500
    end

    read :list_active do
      description "All prefix tags belonging to currently active snapshots"
      prepare build(load: [:snapshot])
      filter expr(snapshot.is_active == true)
      pagination keyset?: true, default_limit: 1000
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

    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if @manage_check
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :snapshot_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :prefix, Cidr do
      allow_nil? false
      public? true
      description "CIDR prefix (e.g. 10.1.2.0/24)"
    end

    attribute :vrf, :string do
      public? true
      description "Optional VRF/routing domain name"
    end

    attribute :tags, Jsonb do
      allow_nil? false
      default []
      public? true
      description "Ordered tag list (most-specific intent at the front when stored as a chain)"
    end

    attribute :site, :string do
      public? true
    end

    attribute :role, :string do
      public? true
    end

    attribute :tenant, :string do
      public? true
    end

    attribute :status, :string do
      public? true
      description "IPAM status for the prefix (active, reserved, deprecated, ...)"
    end

    attribute :partition, :string do
      public? true
      description "Reserved partition scope; unused in v1 (global tags)"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :snapshot, ServiceRadar.PrefixTags.Snapshot do
      define_attribute? false
      source_attribute :snapshot_id
      allow_nil? false
    end
  end
end
