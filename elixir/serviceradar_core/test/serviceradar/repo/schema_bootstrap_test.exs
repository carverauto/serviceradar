defmodule ServiceRadar.Repo.SchemaBootstrapTest do
  @moduledoc """
  Contract for the bootstrap classifier.

  These cases previously existed only against
  `ServiceRadar.Cluster.StartupMigrations.classify_bootstrap_state/2`, which is now a delegate.
  They are asserted here too because this module is the one every entry point calls -- service
  startup, the CI fixture template, and `mix serviceradar.db.migrate` -- so its contract should
  be stated where it lives rather than only where it used to.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Repo.SchemaBootstrap

  describe "classify_state/2" do
    test "an empty database with no history is a fresh install" do
      assert :empty = SchemaBootstrap.classify_state([], 0)
    end

    test "migration history wins over object count" do
      # A database that recorded any migration is an upgrade, however few platform objects it
      # happens to hold. Baselining over it would overwrite a real schema.
      assert :migrated = SchemaBootstrap.classify_state([20_260_519_162_000], 0)
      assert :migrated = SchemaBootstrap.classify_state([20_260_519_162_000], 42)
    end

    test "platform objects without history fail closed" do
      assert {:ambiguous, %{platform_object_count: 2, migration_versions: []}} =
               SchemaBootstrap.classify_state([], 2)
    end

    test "duplicate and unsorted versions do not change the verdict" do
      # Versions arrive from three separate ledgers, so duplicates are expected.
      assert :migrated =
               SchemaBootstrap.classify_state(
                 [20_260_707_120_000, 20_260_519_162_000, 20_260_707_120_000],
                 0
               )
    end
  end

  describe "migration_version_from_file/1" do
    test "reads the version prefix from a migration filename" do
      assert SchemaBootstrap.migration_version_from_file(
               "priv/repo/migrations/20260126120000_move_public_schema_objects_to_platform.exs"
             ) == 20_260_126_120_000
    end
  end

  describe "baseline_metadata!/0" do
    test "the committed baseline declares the fields startup reads" do
      metadata = SchemaBootstrap.baseline_metadata!()

      assert is_integer(metadata["included_through"])
      assert is_binary(metadata["schema_file"])
      assert is_binary(metadata["schema_sha256"])
    end
  end
end
