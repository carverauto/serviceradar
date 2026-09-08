defmodule ServiceRadar.Inventory.ScalarUbuntuOsvCandidateSeedIndexMigrationTest do
  use ExUnit.Case, async: true

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20260904000100_add_scalar_ubuntu_osv_candidate_seed_index.exs",
                    __DIR__
                  )
  @external_resource @migration_path
  @schema "platform"
  @index_name "advisory_package_assertions_scalar_osv_seed_idx"

  test "creates the exact scalar Ubuntu OSV candidate-seed index concurrently" do
    migration = File.read!(@migration_path)

    assert migration =~ "@disable_ddl_transaction true"
    assert migration =~ "@disable_migration_lock true"
    assert migration =~ ~s(@index "#{@index_name}")
    assert migration =~ ~S(CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index})

    assert migration =~
             "(provider, feed_key, package_type, namespace, release, source_package)"

    assert migration =~ "INCLUDE (id, cve_id, advisory_ref)"

    for predicate <- [
          "source_kind = 'ubuntu_osv'",
          "assertion_shape = 'scalar'",
          "product_set_ref IS NULL",
          "product_scope = 'source_to_binary'",
          "version_scheme = 'deb'"
        ] do
      assert migration =~ predicate
    end

    assert migration =~ ~s(@schema "#{@schema}")
    assert migration =~ ~S(DROP INDEX CONCURRENTLY IF EXISTS #{@schema}.#{@index})
  end
end
