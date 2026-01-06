defmodule ServiceRadar.Repo.Migrations.CreateEdgeSites do
  @moduledoc """
  Creates the edge_sites table for tracking customer edge deployment locations.

  Edge sites represent physical or logical locations where customers deploy
  NATS leaf servers and collectors, enabling local message buffering and
  WAN resilience.
  """

  use Ecto.Migration

  def up do
    create table(:edge_sites, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :tenant_id, references(:tenants, type: :uuid, on_delete: :delete_all), null: false

      add :name, :string, null: false
      add :slug, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :nats_leaf_url, :string

      add :last_seen_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:edge_sites, [:tenant_id])
    create unique_index(:edge_sites, [:tenant_id, :slug])
    create index(:edge_sites, [:status])
  end

  def down do
    drop table(:edge_sites)
  end
end
