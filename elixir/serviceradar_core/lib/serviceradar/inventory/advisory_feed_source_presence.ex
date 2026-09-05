defmodule ServiceRadar.Inventory.AdvisoryFeedSourcePresence do
  @moduledoc """
  Narrow ledger of source objects observed in complete advisory generations.

  Presence is intentionally separate from advisory content so an unchanged
  snapshot can prove completeness without rewriting the advisory corpus.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @fields [
    :provider,
    :feed_key,
    :generation,
    :source_object_id,
    :content_modified_at,
    :observed_at,
    :metadata
  ]

  postgres do
    table "advisory_feed_source_presence"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? true
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      primary? true
      accept @fields
      upsert? true
      upsert_identity :unique_source_presence
      upsert_fields [:content_modified_at, :observed_at, :metadata]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action_type(:create)
    admin_action_type(:destroy)
  end

  attributes do
    uuid_primary_key :id

    attribute :provider, :string, allow_nil?: false, public?: true
    attribute :feed_key, :string, allow_nil?: false, public?: true
    attribute :generation, :integer, allow_nil?: false, public?: true
    attribute :source_object_id, :string, allow_nil?: false, public?: true
    attribute :content_modified_at, :utc_datetime_usec, public?: true
    attribute :observed_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :metadata, :map, allow_nil?: false, default: %{}, public?: true
  end

  identities do
    identity :unique_source_presence, [:provider, :feed_key, :generation, :source_object_id]
  end
end
