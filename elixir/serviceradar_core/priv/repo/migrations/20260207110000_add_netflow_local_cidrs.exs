defmodule ServiceRadar.Repo.Migrations.AddNetflowLocalCidrs do
  @moduledoc """
  Adds the NetFlow local CIDR configuration table.

  This table is used by SRQL (and background enrichment) to classify flow
  directionality (inbound/outbound/internal/external) based on a deployment's
  configured "local" networks.
  """

  use Ecto.Migration

  def up do
    create table(:netflow_local_cidrs, primary_key: false, prefix: "platform") do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)

      # Optional partition scoping (matches ocsf_network_activity.partition).
      # NULL means "applies to all partitions".
      add(:partition, :text)

      add(:label, :text)
      add(:cidr, :cidr, null: false)
      add(:enabled, :boolean, null: false, default: true)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:netflow_local_cidrs, [:partition], prefix: "platform"))
    create(index(:netflow_local_cidrs, [:enabled], prefix: "platform"))
    create(unique_index(:netflow_local_cidrs, [:partition, :cidr], prefix: "platform"))

    execute("""
    CREATE INDEX IF NOT EXISTS netflow_local_cidrs_cidr_gist_enabled_idx
    ON platform.netflow_local_cidrs
    USING GIST (cidr)
    WHERE enabled
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.netflow_local_cidrs_cidr_gist_enabled_idx")

    drop(unique_index(:netflow_local_cidrs, [:partition, :cidr], prefix: "platform"))
    drop(index(:netflow_local_cidrs, [:enabled], prefix: "platform"))
    drop(index(:netflow_local_cidrs, [:partition], prefix: "platform"))
    drop(table(:netflow_local_cidrs, prefix: "platform"))
  end
end
