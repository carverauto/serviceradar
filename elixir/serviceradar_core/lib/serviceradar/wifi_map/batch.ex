defmodule ServiceRadar.WifiMap.Batch do
  @moduledoc "Ingestion batch audit record for WiFi-map plugin results."

  use Ash.Resource,
    domain: ServiceRadar.WifiMap,
    data_layer: AshPostgres.DataLayer

  @fields [
    :source_id,
    :collection_mode,
    :collection_timestamp,
    :reference_hash,
    :source_files,
    :row_counts,
    :diagnostics
  ]

  postgres do
    table("wifi_map_batches")
    repo(ServiceRadar.Repo)
    schema("platform")
    migrate?(false)
  end

  actions do
    defaults([:read, :destroy])

    create :upsert do
      accept(@fields)
      upsert?(true)
      upsert_identity(:source_time_mode)
      upsert_fields([:reference_hash, :source_files, :row_counts, :diagnostics])
    end
  end

  attributes do
    uuid_primary_key(:id, source: :batch_id)

    attribute :source_id, :uuid do
      allow_nil?(false)
      public?(true)
    end

    attribute :collection_mode, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :collection_timestamp, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
    end

    attribute :reference_hash, :string do
      public?(true)
    end

    attribute :source_files, :map do
      allow_nil?(false)
      default(%{})
      public?(true)
    end

    attribute :row_counts, :map do
      allow_nil?(false)
      default(%{})
      public?(true)
    end

    attribute :diagnostics, :map do
      allow_nil?(false)
      default(%{})
      public?(true)
    end

    create_timestamp(:inserted_at)
  end

  identities do
    identity(:source_time_mode, [:source_id, :collection_timestamp, :collection_mode])
  end
end
