defmodule ServiceRadar.Analytics.StarRocks.Schema do
  @moduledoc """
  The versioned StarRocks DDL under `priv/starrocks`, as data.

  The files are read at compile time and baked into the module, so a release
  carries its own schema and `SchemaMigrator` never depends on a priv directory
  being staged next to it. Each `NNNN_name.sql` file is one migration; its
  number is the version recorded in the warehouse ledger.

  The files pin the database name `serviceradar` and `replication_num` 3.
  `retarget/3` rewrites both for the deployment, which is what lets a single
  node Compose warehouse and a three-replica cluster share one set of files.
  """

  @dir Path.expand("../../../../priv/starrocks", __DIR__)
  @file_pattern ~r/^(\d{4})_([a-z0-9_]+)\.sql$/
  @database_pattern ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @add_column_pattern ~r/^ALTER\s+TABLE\s+(\S+)\s+ADD\s+COLUMN\s+`?([A-Za-z_][A-Za-z0-9_]*)`?\s/i

  @paths @dir |> Path.join("*.sql") |> Path.wildcard() |> Enum.sort()

  for path <- @paths do
    @external_resource path
  end

  @sources Enum.map(@paths, &{Path.basename(&1), File.read!(&1)})

  @type migration :: %{
          version: pos_integer(),
          name: String.t(),
          checksum: String.t(),
          statements: [String.t()]
        }

  @doc "Every shipped migration, ordered by version."
  @spec migrations() :: [migration()]
  def migrations, do: build(@sources)

  @doc false
  @spec build([{String.t(), String.t()}]) :: [migration()]
  def build(sources) when is_list(sources) do
    migrations =
      sources
      |> Enum.map(fn {filename, sql} ->
        case Regex.run(@file_pattern, filename) do
          [_, version, name] ->
            %{
              version: String.to_integer(version),
              name: name,
              checksum: :sha256 |> :crypto.hash(sql) |> Base.encode16(case: :lower),
              statements: statements(sql)
            }

          nil ->
            raise ArgumentError, "StarRocks schema file #{filename} is not named NNNN_name.sql"
        end
      end)
      |> Enum.sort_by(& &1.version)

    versions = Enum.map(migrations, & &1.version)

    if versions != Enum.uniq(versions) do
      raise ArgumentError, "StarRocks schema versions are not unique: #{inspect(versions)}"
    end

    migrations
  end

  @doc """
  Splits a schema file into statements, dropping `--` comment lines.

  The Frontend rejects a comment sent as a statement of its own, so comments
  never leave this module.
  """
  @spec statements(String.t()) :: [String.t()]
  def statements(sql) when is_binary(sql) do
    sql
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "--"))
    |> Enum.join("\n")
    |> String.split(~r/;[ \t]*(\n|\z)/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc "Rewrites the pinned database name and replication factor for this deployment."
  @spec retarget(String.t(), String.t(), pos_integer()) :: String.t()
  def retarget(statement, database, replication_num)
      when is_binary(statement) and is_binary(database) and is_integer(replication_num) and
             replication_num > 0 do
    if !valid_database?(database) do
      raise ArgumentError, "invalid StarRocks database name: #{inspect(database)}"
    end

    statement
    |> String.replace(~r/\bserviceradar(?=\.)/, database)
    |> String.replace(
      ~r/(CREATE\s+DATABASE\s+IF\s+NOT\s+EXISTS\s+)serviceradar\b/i,
      "\\1#{database}"
    )
    |> String.replace(~s("replication_num" = "3"), ~s("replication_num" = "#{replication_num}"))
  end

  @spec valid_database?(term()) :: boolean()
  def valid_database?(database),
    do: is_binary(database) and Regex.match?(@database_pattern, database)

  @doc """
  Recognises `ALTER TABLE t ADD COLUMN c ...`.

  StarRocks has no `ADD COLUMN IF NOT EXISTS`, and the CREATE in 0001 already
  carries every later column, so the migrator has to ask before it adds.
  """
  @spec add_column(String.t()) :: {:ok, {String.t(), String.t()}} | :error
  def add_column(statement) when is_binary(statement) do
    case Regex.run(@add_column_pattern, statement) do
      [_, table, column] -> {:ok, {table |> String.split(".") |> List.last(), column}}
      nil -> :error
    end
  end
end
