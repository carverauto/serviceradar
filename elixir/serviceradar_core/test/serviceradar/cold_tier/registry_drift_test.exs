defmodule ServiceRadar.ColdTier.RegistryDriftTest do
  @moduledoc """
  Cold schema registry drift check (OpenSpec add-tiered-telemetry-offload task 1.2).

  Fails when a registry table's live schema diverges from its registry entry —
  i.e. a migration altered an offloadable table without updating
  `ServiceRadar.ColdTier.Registry` in the same change. Runs only against a real
  database (`mix test --include integration` with a test database configured).
  """

  # DataCase, not a bare ExUnit.Case: this is the only cold-tier test that queries the
  # Repo, and a bare case checks out no sandbox connection, so the query died with
  #
  #   ** (DBConnection.OwnershipError) cannot find ownership process for #PID<...>
  #      (ServiceRadar.Repo) using mode :manual.
  #
  # It never surfaced locally because the whole module is `:integration` and therefore
  # excluded from every run without a database. DataCase also carries `:requires_app`,
  # which the integration target already includes.
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.ColdTier.Registry

  @moduletag :integration

  # registry type -> information_schema udt_name
  @udt %{
    "timestamptz" => "timestamptz",
    "text" => "text",
    "integer" => "int4",
    "bigint" => "int8",
    "double precision" => "float8",
    "boolean" => "bool",
    "uuid" => "uuid",
    "jsonb" => "jsonb",
    "text[]" => "_text"
  }

  test "registry column contracts match the live schema" do
    for entry <- Registry.tables() do
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          ServiceRadar.Repo,
          """
          SELECT column_name, udt_name
          FROM information_schema.columns
          WHERE table_schema = $1 AND table_name = $2
          ORDER BY ordinal_position
          """,
          [Registry.schema(), entry.table]
        )

      live = Map.new(rows, fn [name, udt] -> {name, udt} end)

      assert map_size(live) > 0,
             "#{entry.table}: table not found in schema #{Registry.schema()}"

      registered =
        Map.new(Registry.expected_columns(entry), fn {name, type} ->
          {name, Map.fetch!(@udt, type)}
        end)

      missing_from_registry = Map.keys(live) -- Map.keys(registered)
      missing_from_schema = Map.keys(registered) -- Map.keys(live)

      assert missing_from_registry == [],
             "#{entry.table}: columns exist in the database but not in the cold " <>
               "schema registry (update ServiceRadar.ColdTier.Registry in the same " <>
               "change as the migration): #{inspect(missing_from_registry)}"

      assert missing_from_schema == [],
             "#{entry.table}: registry lists columns the database no longer has: " <>
               "#{inspect(missing_from_schema)}"

      for {name, udt} <- registered do
        assert live[name] == udt,
               "#{entry.table}.#{name}: registry type #{udt} != live type #{live[name]}"
      end
    end
  end
end
