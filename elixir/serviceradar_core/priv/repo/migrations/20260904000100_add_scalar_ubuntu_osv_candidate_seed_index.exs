defmodule ServiceRadar.Repo.Migrations.AddScalarUbuntuOsvCandidateSeedIndex do
  @moduledoc """
  Adds the bounded scalar Ubuntu OSV candidate-seed lookup index.

  Concurrent DDL keeps assertion ingestion available while the index is built.
  PostgreSQL requires it to run outside Ecto's transaction and migration lock.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @schema "platform"
  @index "advisory_package_assertions_scalar_osv_seed_idx"

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index}
      ON #{@schema}.advisory_package_assertions
         (provider, feed_key, package_type, namespace, release, source_package)
      INCLUDE (id, cve_id, advisory_ref)
      WHERE source_kind = 'ubuntu_osv'
        AND assertion_shape = 'scalar'
        AND product_set_ref IS NULL
        AND product_scope = 'source_to_binary'
        AND version_scheme = 'deb'
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@schema}.#{@index}")
  end
end
