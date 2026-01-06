defmodule ServiceRadar.Repo.Migrations.AddEdgeSiteIdToCollectorPackages do
  @moduledoc """
  Adds edge_site_id to collector_packages table.

  When a collector is associated with an edge site, it will connect to the
  local NATS leaf server instead of the SaaS NATS cluster directly.
  """

  use Ecto.Migration

  def up do
    alter table(:collector_packages) do
      add :edge_site_id, references(:edge_sites, type: :uuid, on_delete: :nilify_all)
    end

    create index(:collector_packages, [:edge_site_id])
  end

  def down do
    alter table(:collector_packages) do
      remove :edge_site_id
    end
  end
end
