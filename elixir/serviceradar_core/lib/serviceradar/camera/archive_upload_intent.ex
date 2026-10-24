defmodule ServiceRadar.Camera.ArchiveUploadIntent do
  @moduledoc """
  Immutable object identity derived from a frozen block and its bound destination.

  This is preparation only. It grants no storage access, dispatch permission,
  verification, availability or deletion authority. There are no update or
  delete actions; dispatch observations belong to a separate lifecycle.

  The create action is a trusted persistence primitive. Application callers use
  `ArchiveUploads.prepare/3`, which owns the lease fence and value derivation.
  """
  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "camera_archive_upload_intents"
    schema "platform"
    repo ServiceRadar.Repo

    references do
      reference :recording_block, on_delete: :restrict
      reference :archive_binding, on_delete: :restrict
    end

    check_constraints do
      check_constraint :object_role, "camera_upload_intent_object_bounds",
        check: """
        schema_version = 1 AND
        ((object_role = 'init' AND byte_length BETWEEN 1 AND 1048576) OR
         (object_role = 'media' AND byte_length BETWEEN 1 AND 536870912)) AND
        object_sha256 ~ '^[0-9a-f]{64}$' AND
        descriptor_sha256 ~ '^[0-9a-f]{64}$' AND
        destination_sha256 ~ '^[0-9a-f]{64}$'
        """
    end
  end

  actions do
    defaults [:read]

    create :prepare do
      accept [
        :recording_block_id,
        :archive_binding_id,
        :descriptor_sha256,
        :destination_sha256,
        :object_role,
        :object_key,
        :byte_length,
        :object_sha256
      ]
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :schema_version, :integer,
      allow_nil?: false,
      default: 1,
      constraints: [min: 1, max: 1]

    attribute :recording_block_id, :uuid, allow_nil?: false
    attribute :archive_binding_id, :uuid, allow_nil?: false

    attribute :descriptor_sha256, :string,
      allow_nil?: false,
      constraints: [min_length: 64, max_length: 64]

    attribute :destination_sha256, :string,
      allow_nil?: false,
      constraints: [min_length: 64, max_length: 64]

    attribute :object_role, :atom, allow_nil?: false, constraints: [one_of: [:init, :media]]
    attribute :object_key, :string, allow_nil?: false, constraints: [max_length: 128]
    attribute :byte_length, :integer, allow_nil?: false, constraints: [min: 1, max: 536_870_912]

    attribute :object_sha256, :string,
      allow_nil?: false,
      constraints: [min_length: 64, max_length: 64]

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :recording_block, ServiceRadar.Camera.RecordingBlock,
      allow_nil?: false,
      define_attribute?: false

    belongs_to :archive_binding, ServiceRadar.Camera.ArchiveBinding,
      allow_nil?: false,
      define_attribute?: false
  end

  identities do
    identity :block_role, [:recording_block_id, :object_role]
  end
end
