defmodule ServiceRadar.Repo.Migrations.CreatePrefixTagsCatalogView do
  @moduledoc """
  StarRocks JDBC catalog cannot map PostgreSQL `cidr`. Expose prefix tags as
  text for attribution/enrichment joins. The view is read-only current-state;
  it is not a telemetry serving path.
  """
  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE VIEW platform.prefix_tags_catalog AS
    SELECT
      prefix::text AS prefix,
      vrf,
      site,
      role,
      tenant,
      status,
      partition
    FROM platform.prefix_tags
    """)
  end

  def down do
    execute("DROP VIEW IF EXISTS platform.prefix_tags_catalog")
  end
end
