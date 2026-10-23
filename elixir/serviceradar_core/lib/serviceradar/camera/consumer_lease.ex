defmodule ServiceRadar.Camera.ConsumerLease do
  @moduledoc """
  An independently expiring viewer, recorder or analysis consumer of an ingest.

  `IngestOwnership` serializes writes with the owner row, bounds expiration by
  the owner lease, and rejects mutations from superseded epochs.
  """

  use Ash.Resource,
    domain: ServiceRadar.Camera,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "camera_consumer_leases"
    schema "platform"
    repo ServiceRadar.Repo

    custom_indexes do
      index [:ingest_owner_id, :owner_epoch, :expires_at]
    end

    check_constraints do
      check_constraint :owner_epoch, "camera_consumer_epoch_positive", check: "owner_epoch > 0"
    end
  end

  actions do
    defaults [:read, :destroy]

    create :acquire do
      accept [:ingest_owner_id, :owner_epoch, :kind, :consumer_key, :expires_at]
      upsert? true
      upsert_identity :consumer
      upsert_fields [:expires_at]
    end

    update :renew do
      accept [:expires_at]
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
    attribute :owner_epoch, :integer, allow_nil?: false, constraints: [min: 1]

    attribute :kind, :atom,
      allow_nil?: false,
      constraints: [one_of: [:viewer, :recorder, :analysis]]

    attribute :consumer_key, :uuid, allow_nil?: false
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :ingest_owner, ServiceRadar.Camera.IngestOwner do
      allow_nil? false
      define_attribute? false
    end
  end

  identities do
    identity :consumer, [:ingest_owner_id, :owner_epoch, :kind, :consumer_key]
  end
end
