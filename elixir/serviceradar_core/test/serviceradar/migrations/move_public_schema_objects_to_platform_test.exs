defmodule ServiceRadar.Migrations.MovePublicSchemaObjectsToPlatformTest do
  @moduledoc """
  Regression coverage for issue #4151.

  The migration relocates every table `public` holds for the current user, excluding the Ecto
  migration ledger. It excluded that ledger by the hardcoded name `schema_migrations`, which is
  correct only when `migration_source` is unset.

  `elixir/web-ng/config/config.exs` sets `migration_source: "ash_schema_migrations"` for the
  shared `ServiceRadar.Repo`. Under that config the migration moved the ledger the Ecto migrator
  was actively holding `SHARE UPDATE EXCLUSIVE` on, and since each migration body runs in a
  `Task.async` (a second pooled connection), the move waited on a lock the migrator would not
  release until the move returned. Neither Postgres nor the BEAM could break that: the holder is
  idle-in-transaction rather than waiting in the database, so there is no cycle to detect.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Repo.Migrations.MovePublicSchemaObjectsToPlatform, as: Migration

  @migration_path Path.expand(
                    "../../../priv/repo/migrations/20260126120000_move_public_schema_objects_to_platform.exs",
                    __DIR__
                  )
  @external_resource @migration_path

  Code.require_file(@migration_path)

  describe "ledger_tables/1" do
    test "excludes the configured migration_source, not just the default name" do
      assert "ash_schema_migrations" in Migration.ledger_tables("ash_schema_migrations")
    end

    test "always excludes the default ledger name as well" do
      assert "schema_migrations" in Migration.ledger_tables("ash_schema_migrations")
    end

    test "returns only the default when migration_source is unset" do
      assert Migration.ledger_tables(nil) == ["schema_migrations"]
    end

    test "does not duplicate when migration_source is the default name" do
      assert Migration.ledger_tables("schema_migrations") == ["schema_migrations"]
    end

    test "treats an empty migration_source as unset" do
      assert Migration.ledger_tables("") == ["schema_migrations"]
    end
  end

  describe "generated SQL" do
    test "the table loop excludes every ledger table" do
      sql = Migration.move_objects_sql(["schema_migrations", "ash_schema_migrations"])

      assert sql =~ "'schema_migrations'"
      assert sql =~ "'ash_schema_migrations'"
    end

    test "a ledger table is never named as a relocation target" do
      sql = Migration.move_objects_sql(["schema_migrations", "ash_schema_migrations"])

      refute sql =~ "ALTER TABLE public.ash_schema_migrations"
    end

    test "a lock timeout names the sequence, view, or materialized view it could not move" do
      sql = Migration.move_objects_sql(["schema_migrations"])

      for {class, catalog} <- [
            {"SEQUENCE", "pg_sequences"},
            {"VIEW", "pg_views"},
            {"MATERIALIZED VIEW", "pg_matviews"}
          ] do
        assert sql =~ catalog

        assert diagnoses_lock_timeout?(sql, class),
               "expected #{class} relocation to name the object and its lock holders"
      end
    end
  end

  # The generated statement is the migration. A class is diagnosed when its
  # ALTER sits in a lock_not_available handler that reports pid, state, and query.
  defp diagnoses_lock_timeout?(sql, class) do
    literal = "ALTER #{class} public.%I SET SCHEMA platform"
    unified = "ALTER %s public.%I SET SCHEMA platform"

    cond do
      String.contains?(sql, literal) ->
        handler_names_holder?(sql, literal)

      String.contains?(sql, unified) and String.contains?(sql, "'#{class}'") ->
        handler_names_holder?(sql, unified)

      true ->
        false
    end
  end

  defp handler_names_holder?(sql, alter) do
    case :binary.match(sql, alter) do
      :nomatch ->
        false

      {pos, length} ->
        rest = binary_part(sql, pos + length, byte_size(sql) - pos - length)
        window = rest |> String.split("END LOOP", parts: 2) |> hd()

        String.contains?(window, "EXCEPTION WHEN lock_not_available") and
          String.contains?(window, "pid=%s state=%s query=%s")
    end
  end
end
