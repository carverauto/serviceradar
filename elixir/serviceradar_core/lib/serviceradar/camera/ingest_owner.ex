defmodule ServiceRadar.Camera.IngestOwner do
  @moduledoc """
  Durable camera/profile ownership and fencing generation.

  Mutations belong to `IngestOwnership`, which locks this row before changing
  ownership or consumers. The row is retained on release so epochs never reset.
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "camera_ingest_owners"
    schema "platform"
    repo ServiceRadar.Repo

    check_constraints do
      check_constraint :epoch, "camera_ingest_owner_epoch_nonnegative", check: "epoch >= 0"

      check_constraint :state, "camera_ingest_owner_lease_present",
        check: "state = 'released' OR (owner_token IS NOT NULL AND lease_expires_at IS NOT NULL)"
    end
  end

  actions do
    defaults [:read]

    create :initialize do
      accept [:camera_source_id, :stream_profile_id]
      upsert? true
      upsert_identity :source_profile
      upsert_fields []
    end

    update :transition do
      accept [:owner_token, :epoch, :state, :lease_expires_at, :relay_session_id]
    end
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :camera_source_id, :uuid, allow_nil?: false
    attribute :stream_profile_id, :uuid, allow_nil?: false
    attribute :owner_token, :uuid, sensitive?: true
    attribute :epoch, :integer, allow_nil?: false, default: 0, constraints: [min: 0]

    attribute :state, :atom,
      allow_nil?: false,
      default: :released,
      constraints: [one_of: [:active, :closing, :released]]

    attribute :lease_expires_at, :utc_datetime_usec
    attribute :relay_session_id, :uuid
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :camera_source, ServiceRadar.Camera.Source do
      allow_nil? false
      define_attribute? false
    end

    belongs_to :stream_profile, ServiceRadar.Camera.StreamProfile do
      allow_nil? false
      define_attribute? false
    end

    belongs_to :relay_session, ServiceRadar.Camera.RelaySession do
      define_attribute? false
    end
  end

  calculations do
    # Loaded in a second statement after FOR UPDATE acquires the lock; a node's
    # wall clock or time spent waiting for the lock cannot extend a stale lease.
    calculate :database_now, :utc_datetime_usec, expr(fragment("clock_timestamp()"))
  end

  identities do
    identity :source_profile, [:camera_source_id, :stream_profile_id]
  end
end
