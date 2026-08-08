defmodule ServiceRadar.PrefixTags.Snapshot do
  @moduledoc """
  Snapshot metadata for a prefix-tag dataset import source.

  Each source (e.g. `netbox`, `manual`) has at most one active snapshot, enforced
  by a partial unique index. Importers write a `building` snapshot, load rows,
  then promote it to `active` (and supersede the previous active) in one
  transaction. The `manual` source is permanent and not replaced by scheduled
  imports.
  """

  use Ash.Resource,
    domain: ServiceRadar.PrefixTags,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @manage_check {ServiceRadar.Policies.Checks.ActorHasPermission,
                 permission: "settings.prefix_tags.manage"}

  @snapshot_create_fields [
    :source,
    :status,
    :source_url,
    :source_etag,
    :source_sha256,
    :fetched_at,
    :promoted_at,
    :is_active,
    :record_count,
    :metadata
  ]

  postgres do
    table "prefix_tag_snapshots"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  code_interface do
    define :create, action: :create
    define :active_for_source, action: :active_for_source
    define :list_active, action: :list_active
    define :by_id, action: :by_id
    define :promote, action: :promote
    define :mark_failed, action: :mark_failed
    define :update_record_count, action: :update_record_count
  end

  actions do
    defaults [:read]

    read :active_for_source do
      get? true
      argument :source, :string, allow_nil?: false
      filter expr(is_active == true and source == ^arg(:source))
    end

    read :list_active do
      filter expr(is_active == true)
    end

    read :by_id do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id))
    end

    create :create do
      accept @snapshot_create_fields
    end

    update :promote do
      accept [:record_count, :metadata, :source_etag, :source_sha256]
      # Field updates are static / DB-now — keep this action fully atomic.
      # Multi-snapshot supersede of the previous active row lives in the
      # importer transaction (NetboxImportWorker.promote_snapshot/3).
      change set_attribute(:is_active, true)
      change set_attribute(:status, "active")
      change atomic_update(:promoted_at, expr(now()))
    end

    update :mark_failed do
      accept [:metadata]
      change set_attribute(:status, "failed")
      change set_attribute(:is_active, false)
    end

    update :update_record_count do
      accept [:record_count]
    end

    update :supersede do
      accept []
      change set_attribute(:is_active, false)
      change set_attribute(:status, "superseded")
    end
  end

  policies do
    bypass always() do
      authorize_if actor_attribute_equals(:role, :system)
    end

    policy action_type(:read) do
      authorize_if always()
    end

    # Snapshot lifecycle mutations are system/importer only; operators manage
    # manual *tags* via PrefixTag, not snapshot rows.
    policy action([:create, :promote, :mark_failed, :update_record_count, :supersede]) do
      authorize_if actor_attribute_equals(:role, :system)
      authorize_if @manage_check
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :source, :string do
      allow_nil? false
      public? true
      description "Import source identifier (netbox, manual, ...)"
    end

    attribute :status, :string do
      allow_nil? false
      default "building"
      public? true
      description "building | active | superseded | failed"
    end

    attribute :source_url, :string do
      public? true
    end

    attribute :source_etag, :string do
      public? true
    end

    attribute :source_sha256, :string do
      public? true
    end

    attribute :fetched_at, :utc_datetime_usec do
      public? true
    end

    attribute :promoted_at, :utc_datetime_usec do
      public? true
    end

    attribute :is_active, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :record_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :prefix_tags, ServiceRadar.PrefixTags.PrefixTag do
      destination_attribute :snapshot_id
    end
  end
end
