defmodule ServiceRadar.Camera.RecorderClaim do
  @moduledoc """
  Retained recorder generation and allocation counter for one source/profile.

  The unique ingest owner supplies the source/profile identity. RecorderOwnership
  locks that owner before this row. Discovery and consumer leases alone do not
  grant recording rights. A new claimant never resumes an old generation.
  """
  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ash.Expr

  postgres do
    table "camera_recorder_claims"
    schema "platform"
    repo ServiceRadar.Repo

    references do
      reference :consumer, on_delete: :nilify
    end

    check_constraints do
      check_constraint :recorder_epoch, "camera_recorder_epoch_nonnegative",
        check: "recorder_epoch >= 0"

      check_constraint :next_block_sequence, "camera_recorder_sequence_nonnegative",
        check: "next_block_sequence >= 0"

      check_constraint :state, "camera_recorder_active_claim_present",
        check: """
        state = 'released' OR (
          claim_token IS NOT NULL AND ingest_epoch > 0 AND recorder_epoch > 0 AND
          relay_session_id IS NOT NULL AND media_ingest_id IS NOT NULL AND
          storage_id IS NOT NULL AND lease_expires_at IS NOT NULL
        )
        """
    end
  end

  actions do
    defaults [:read]

    create :initialize do
      accept [:ingest_owner_id]
      upsert? true
      upsert_identity :owner
      upsert_fields []
    end

    update :transition do
      accept [
        :claim_token,
        :ingest_epoch,
        :recorder_epoch,
        :next_block_sequence,
        :relay_session_id,
        :media_ingest_id,
        :storage_id,
        :consumer_id,
        :lease_expires_at,
        :state
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
    attribute :ingest_owner_id, :uuid, allow_nil?: false
    attribute :claim_token, :uuid, sensitive?: true
    attribute :ingest_epoch, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :recorder_epoch, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :next_block_sequence, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :relay_session_id, :uuid
    attribute :media_ingest_id, :string, constraints: [max_length: 128]
    attribute :storage_id, :uuid
    attribute :consumer_id, :uuid
    attribute :lease_expires_at, :utc_datetime_usec

    attribute :state, :atom,
      allow_nil?: false,
      default: :released,
      constraints: [one_of: [:active, :released]]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :ingest_owner, ServiceRadar.Camera.IngestOwner,
      allow_nil?: false,
      define_attribute?: false

    belongs_to :relay_session, ServiceRadar.Camera.RelaySession, define_attribute?: false
    belongs_to :consumer, ServiceRadar.Camera.ConsumerLease, define_attribute?: false
  end

  calculations do
    calculate :database_now, :utc_datetime_usec, expr(fragment("clock_timestamp()"))
  end

  identities do
    identity :owner, [:ingest_owner_id]
  end
end
