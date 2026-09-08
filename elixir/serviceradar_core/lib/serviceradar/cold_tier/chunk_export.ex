defmodule ServiceRadar.ColdTier.ChunkExport do
  @moduledoc """
  Manifest row for one exported hypertable chunk.

  The manifest is the cold tier's commit protocol: objects on the deployment
  bucket are readable/prunable only through `verified` manifest rows, and
  `drop_chunks` on a registry table is gated on the chunk's verified entry.
  Status flow: pending -> exported -> verified -> pruned, with quarantined as
  the poison-chunk side state. Maps to `platform.cold_chunk_exports`
  (raw SQL migration 20260716200000).
  """

  use Ash.Resource,
    domain: ServiceRadar.ColdTier,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "cold_chunk_exports"
    repo ServiceRadar.Repo
    schema "platform"
    # Managed by raw SQL migration (identity PK, CHECK constraints)
    migrate? false
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :table_name,
        :chunk_name,
        :range_start,
        :range_end,
        :object_keys,
        :row_count,
        :bytes,
        :content_checksum,
        :status,
        :attempts,
        :last_error,
        :exported_at,
        :verified_at,
        :pruned_at
      ]

      upsert? true
      upsert_identity :table_chunk
    end

    update :update do
      accept [
        :object_keys,
        :row_count,
        :bytes,
        :content_checksum,
        :status,
        :attempts,
        :last_error,
        :exported_at,
        :verified_at,
        :pruned_at
      ]
    end
  end

  attributes do
    integer_primary_key :id, writable?: false, generated?: true

    attribute :table_name, :string, allow_nil?: false
    attribute :chunk_name, :string, allow_nil?: false
    attribute :range_start, :utc_datetime_usec, allow_nil?: false
    attribute :range_end, :utc_datetime_usec, allow_nil?: false
    attribute :object_keys, {:array, :string}, default: []
    attribute :row_count, :integer
    attribute :bytes, :integer
    attribute :content_checksum, :string

    attribute :status, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :exported, :verified, :quarantined, :pruned]]

    attribute :attempts, :integer, allow_nil?: false, default: 0
    attribute :last_error, :string
    attribute :exported_at, :utc_datetime_usec
    attribute :verified_at, :utc_datetime_usec
    attribute :pruned_at, :utc_datetime_usec

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :table_chunk, [:table_name, :chunk_name]
  end
end
