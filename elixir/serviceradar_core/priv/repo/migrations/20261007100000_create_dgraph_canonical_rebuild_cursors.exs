defmodule ServiceRadar.Repo.Migrations.CreateDgraphCanonicalRebuildCursors do
  @moduledoc """
  Progress of the chunked, resumable Dgraph canonical rebuild
  (`update-dgraph-nif-async-calls`).

  One row per rebuild name. It records which phase the rebuild reached and the
  next upsert chunk to write, together with a fingerprint of the desired edge
  set the progress belongs to. A run whose desired set has a different
  fingerprint discards the row and starts over. A completed rebuild deletes
  its row.

  Schema only: creates an empty table and rewrites nothing.
  """
  use Ecto.Migration

  def up do
    create table(:dgraph_canonical_rebuild_cursors, primary_key: false, prefix: "platform") do
      add :name, :text, primary_key: true
      add :fingerprint, :text, null: false
      add :phase, :text, null: false
      add :next_chunk, :integer, null: false, default: 0

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end
  end

  def down do
    drop_if_exists table(:dgraph_canonical_rebuild_cursors, prefix: "platform")
  end
end
