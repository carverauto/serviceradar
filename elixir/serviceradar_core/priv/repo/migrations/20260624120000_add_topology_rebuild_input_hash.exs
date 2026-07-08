defmodule ServiceRadar.Repo.Migrations.AddTopologyRebuildInputHash do
  @moduledoc """
  Adds a durable, cross-replica skip-guard fingerprint to the runtime topology
  projection metadata.

  The canonical topology rebuild previously cached its "observed graph unchanged"
  fingerprint in a process-local `:persistent_term`, which is wiped on every pod
  restart. Each rollout therefore forced a cold full canonical rebuild on every
  replica (the rollout-correlated CNPG CPU burst). Persisting the fingerprint on
  the existing `platform.runtime_topology_projection_meta` row makes the guard
  durable across restarts and shared across replicas.

  Both columns are NULLABLE with no default so existing rows read `nil` and the
  guard fails open (one rebuild post-deploy, then steady-state skips).
  """
  use Ecto.Migration

  def up do
    create_if_not_exists table(:runtime_topology_projection_meta,
                           primary_key: false,
                           prefix: "platform"
                         ) do
      add :projection_name, :text, null: false, primary_key: true
      add :refreshed_at, :utc_datetime_usec, null: false
      add :row_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    execute(
      "ALTER TABLE platform.runtime_topology_projection_meta ADD COLUMN IF NOT EXISTS input_hash text",
      "ALTER TABLE platform.runtime_topology_projection_meta DROP COLUMN IF EXISTS input_hash"
    )

    execute(
      "ALTER TABLE platform.runtime_topology_projection_meta ADD COLUMN IF NOT EXISTS input_hashed_at timestamp(6) without time zone",
      "ALTER TABLE platform.runtime_topology_projection_meta DROP COLUMN IF EXISTS input_hashed_at"
    )
  end

  def down do
    execute(
      "ALTER TABLE platform.runtime_topology_projection_meta DROP COLUMN IF EXISTS input_hashed_at",
      "ALTER TABLE platform.runtime_topology_projection_meta ADD COLUMN IF NOT EXISTS input_hashed_at timestamp(6) without time zone"
    )

    execute(
      "ALTER TABLE platform.runtime_topology_projection_meta DROP COLUMN IF EXISTS input_hash",
      "ALTER TABLE platform.runtime_topology_projection_meta ADD COLUMN IF NOT EXISTS input_hash text"
    )
  end
end
