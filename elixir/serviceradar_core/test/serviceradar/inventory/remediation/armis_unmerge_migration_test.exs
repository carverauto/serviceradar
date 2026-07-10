defmodule ServiceRadar.Inventory.Remediation.ArmisUnmergeMigrationTest do
  use ExUnit.Case, async: true

  @migration_path "priv/repo/migrations/20260709210000_add_armis_unmerge_owner_lookup_indexes.exs"

  test "concurrent index retries replace interrupted invalid relations" do
    migration = File.read!(@migration_path)

    assert migration =~ "i.indisvalid AND i.indisready AND i.indislive"
    assert migration =~ ":invalid ->"

    assert migration =~
             ~S|execute("DROP INDEX CONCURRENTLY IF EXISTS platform.#{index_name}")|

    for index_name <- [
          "device_identifiers_mac_tokens_gin_idx",
          "ocsf_devices_display_mac_tokens_gin_idx"
        ] do
      create = "CREATE INDEX CONCURRENTLY IF NOT EXISTS #{index_name}"

      assert migration =~ create
    end
  end
end
