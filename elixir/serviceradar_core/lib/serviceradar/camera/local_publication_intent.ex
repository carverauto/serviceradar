defmodule ServiceRadar.Camera.LocalPublicationIntent do
  @moduledoc """
  Immutable acknowledgement that Core reconciled a local intent with its frozen block.

  This is not a qualified local copy, storage receipt, playback permission or
  deletion authority. Application callers use `LocalPublicationIntents.accept/2`;
  the create action is a trusted persistence primitive with no update/delete API.
  """
  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "camera_local_publication_intents"
    schema "platform"
    repo ServiceRadar.Repo

    references do
      reference :recording_block, on_delete: :restrict
    end

    check_constraints do
      check_constraint :intent_sha256, "camera_local_intent_hashes",
        check: """
        block_key ~ '^[0-9a-f]{64}$' AND
        descriptor_sha256 ~ '^[0-9a-f]{64}$' AND
        intent_sha256 ~ '^[0-9a-f]{64}$'
        """
    end
  end

  actions do
    defaults [:read]

    create :acknowledge do
      accept [
        :id,
        :recording_block_id,
        :storage_id,
        :block_key,
        :descriptor_sha256,
        :intent_sha256
      ]
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false
    attribute :recording_block_id, :uuid, allow_nil?: false
    attribute :storage_id, :uuid, allow_nil?: false
    attribute :block_key, :string, allow_nil?: false, constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :descriptor_sha256, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :intent_sha256, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :recording_block, ServiceRadar.Camera.RecordingBlock,
      allow_nil?: false,
      define_attribute?: false
  end

  identities do
    identity :block, [:recording_block_id]
  end
end
