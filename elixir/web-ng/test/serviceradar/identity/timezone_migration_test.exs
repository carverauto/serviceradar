defmodule ServiceRadarWebNG.TimezoneMigrationTest do
  use ExUnit.Case, async: true

  @moduletag :db_free

  test "generated migration adds the non-null UTC preference default" do
    migration =
      "../../../../serviceradar_core/priv/repo/migrations/*_add_user_timezone_preference.exs"
      |> Path.expand(__DIR__)
      |> Path.wildcard()
      |> Enum.reject(&String.ends_with?(&1, "_extensions_1.exs"))

    assert [migration] = migration
    assert File.read!(migration) =~ "add :timezone, :text, null: false, default: \"Etc/UTC\""

    baseline =
      "../../../../serviceradar_core/priv/repo/baseline/platform_schema.sql"
      |> Path.expand(__DIR__)
      |> File.read!()

    assert baseline =~ "timezone text DEFAULT 'Etc/UTC'::text NOT NULL"
  end
end
