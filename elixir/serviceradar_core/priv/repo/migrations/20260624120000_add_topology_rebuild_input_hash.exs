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

  def change do
    alter table(:runtime_topology_projection_meta, prefix: "platform") do
      add :input_hash, :text
      add :input_hashed_at, :utc_datetime_usec
    end
  end
end
