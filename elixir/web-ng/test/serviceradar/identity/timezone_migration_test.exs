defmodule ServiceRadarWebNG.TimezoneMigrationTest do
  use ExUnit.Case, async: true

  @moduletag :db_free

  test "timezone migrations add and then verify the non-null UTC preference default" do
    add_migration =
      "../../../../serviceradar_core/priv/repo/migrations/*_add_user_timezone_preference.exs"
      |> Path.expand(__DIR__)
      |> Path.wildcard()
      |> Enum.reject(&String.ends_with?(&1, "_extensions_1.exs"))

    verify_migration =
      "../../../../serviceradar_core/priv/repo/migrations/*_verify_user_timezone_preference.exs"
      |> Path.expand(__DIR__)
      |> Path.wildcard()

    assert [add_migration] = add_migration
    assert [verify_migration] = verify_migration

    assert File.read!(add_migration) =~
             "add :timezone, :text, null: false, default: \"Etc/UTC\""

    verify_source = File.read!(verify_migration)

    assert verify_source =~ "information_schema.columns"
    assert verify_source =~ "data_type = 'text'"
    assert verify_source =~ "is_nullable = 'NO'"
    assert verify_source =~ "column_default = '''Etc/UTC''::text'"
    assert verify_source =~ "RAISE EXCEPTION"
    assert verify_source =~ "version has already run on persistent clusters"

    assert migration_version(verify_migration) > migration_version(add_migration)
    assert migration_version(verify_migration) > 20_260_830_220_000
  end

  defp migration_version(path) do
    path
    |> Path.basename()
    |> String.split("_", parts: 2)
    |> hd()
    |> String.to_integer()
  end
end
