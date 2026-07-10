defmodule ServiceRadar.Inventory.Remediation.ArmisUnmergeMigrationTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Repo.Migrations.AddArmisUnmergeOwnerLookupIndexes, as: Migration

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20260709210000_add_armis_unmerge_owner_lookup_indexes.exs",
                    __DIR__
                  )
  @external_resource @migration_path

  Code.require_file(@migration_path)

  test "classifies concurrent-index catalog state fail closed" do
    assert Migration.classify_index_rows([]) == :missing
    assert Migration.classify_index_rows([["i", true]]) == :valid
    assert Migration.classify_index_rows([["i", false]]) == :invalid

    assert Migration.classify_index_rows([["r", false]]) ==
             {:unexpected_relation, "r"}
  end

  test "an interrupted invalid index is dropped before it is recreated" do
    index_name = "device_identifiers_mac_tokens_gin_idx"
    create_statement = "CREATE INDEX CONCURRENTLY IF NOT EXISTS #{index_name}"

    assert Migration.repair_commands(:invalid, index_name, create_statement) == [
             "DROP INDEX CONCURRENTLY IF EXISTS platform.#{index_name}",
             create_statement
           ]

    assert Migration.repair_commands(:missing, index_name, create_statement) == [create_statement]
    assert Migration.repair_commands(:valid, index_name, create_statement) == []

    assert_raise RuntimeError, ~r/expected platform\.#{index_name} to be an index/, fn ->
      Migration.repair_commands({:unexpected_relation, "r"}, index_name, create_statement)
    end
  end

  test "migration inspects every usable-state flag and defines both indexes" do
    migration = File.read!(@migration_path)

    assert migration =~ "@disable_ddl_transaction true"
    assert migration =~ "@disable_migration_lock true"
    assert migration =~ "i.indisvalid AND i.indisready AND i.indislive"

    for index_name <- [
          "device_identifiers_mac_tokens_gin_idx",
          "ocsf_devices_display_mac_tokens_gin_idx"
        ] do
      create = "CREATE INDEX CONCURRENTLY IF NOT EXISTS #{index_name}"

      assert migration =~ create
    end
  end
end
