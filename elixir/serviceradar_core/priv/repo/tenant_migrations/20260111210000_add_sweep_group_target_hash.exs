defmodule ServiceRadar.Repo.TenantMigrations.AddSweepGroupTargetHash do
  @moduledoc """
  Adds target_hash columns to sweep_groups for config change detection.

  These columns track the hash of compiled target IPs, allowing the system
  to detect when the target list has changed due to device inventory updates.
  """

  use Ecto.Migration

  def up do
    alter table(:sweep_groups, prefix: prefix()) do
      add :target_hash, :text
      add :target_hash_updated_at, :utc_datetime
    end
  end

  def down do
    alter table(:sweep_groups, prefix: prefix()) do
      remove :target_hash
      remove :target_hash_updated_at
    end
  end
end
