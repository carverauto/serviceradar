defmodule ServiceRadar.ColdTier.Verification do
  @moduledoc """
  Engine-stable export verification (spike 0.2): builds the SAME logical
  aggregate for PostgreSQL (primary) and DuckDB-over-parquet (head) from one
  definition, so the two sides can never drift apart:

      count(*), min/max epoch-microseconds, 60-bit-md5 content sum over
      `epoch_us || '|' || <checksum column serializations>`

  Serialization rules (verified cross-engine): epoch micros via
  extract/epoch_us; md5-hex prefix (15 hex chars = 60 bits) to bigint; float
  columns quantized `floor(value * 1e6)::bigint` (raw float `::text`, `round()`,
  `hashtext()` and timestamp text are all engine-divergent — banned).
  Detects both row loss and content mutation; proven in spike 0.2b.
  """

  alias ServiceRadar.ColdTier.Registry
  alias ServiceRadar.ColdTier.Registry.Table

  @type result :: %{
          row_count: integer(),
          min_epoch_us: integer() | nil,
          max_epoch_us: integer() | nil,
          checksum: String.t() | nil
        }

  @doc """
  Columns feeding the content checksum: the registry tiebreakers, or a
  per-table content fallback for tables without a unique key.
  """
  @spec checksum_columns(Table.t()) :: [String.t()]
  def checksum_columns(%Table{tiebreakers: [], table: "ocsf_network_activity"}),
    do: ["src_endpoint_ip", "dst_endpoint_ip", "bytes_total"]

  def checksum_columns(%Table{tiebreakers: [], columns: columns}),
    do: columns |> Enum.take(3) |> Enum.map(fn {name, _t, _c} -> name end)

  def checksum_columns(%Table{tiebreakers: tiebreakers}), do: tiebreakers

  @doc "Verification SELECT for the primary, over `platform.<table>` with $1/$2 time bounds."
  @spec primary_sql(Table.t()) :: String.t()
  def primary_sql(%Table{} = entry) do
    time = ~s("#{entry.time_column}")
    serial = pg_serialization(entry)

    """
    SELECT
      count(*)::bigint,
      min((extract(epoch FROM #{time}) * 1000000)::bigint),
      max((extract(epoch FROM #{time}) * 1000000)::bigint),
      sum(('x' || substr(md5(#{serial}), 1, 15))::bit(60)::bigint)::numeric::text
    FROM #{Registry.qualified_table(entry)}
    WHERE #{time} >= $1 AND #{time} < $2
    """
  end

  @doc "Verification SELECT for the head via read_parquet over one object URL."
  @spec parquet_sql(Table.t(), String.t()) :: String.t()
  def parquet_sql(%Table{} = entry, object_url) do
    time_col = entry.time_column
    serial = duckdb_serialization(entry)

    """
    SELECT
      CAST(count(*) AS bigint),
      CAST(min(epoch_us(CAST(r['#{time_col}'] AS timestamptz))) AS bigint),
      CAST(max(epoch_us(CAST(r['#{time_col}'] AS timestamptz))) AS bigint),
      CAST(sum(CAST('0x' || substr(md5(#{serial}), 1, 15) AS BIGINT)) AS varchar)
    FROM read_parquet('#{object_url}') r
    """
  end

  @doc "Shape a result row (either engine) into the comparable map."
  @spec to_result([term()]) :: result()
  def to_result([count, min_us, max_us, checksum]) do
    %{
      row_count: count,
      min_epoch_us: min_us,
      max_epoch_us: max_us,
      checksum: checksum && to_string(checksum)
    }
  end

  @doc "Whether two verification results agree."
  @spec match?(result(), result()) :: boolean()
  def match?(a, b), do: Map.take(a, keys()) == Map.take(b, keys())

  defp keys, do: [:row_count, :min_epoch_us, :max_epoch_us, :checksum]

  defp pg_serialization(entry) do
    time = ~s("#{entry.time_column}")
    head = "((extract(epoch FROM #{time}) * 1000000)::bigint)::text"

    parts =
      for col <- checksum_columns(entry) do
        case column_type(entry, col) do
          "double precision" -> ~s{coalesce((floor("#{col}" * 1000000)::bigint)::text, '')}
          _ -> ~s{coalesce("#{col}"::text, '')}
        end
      end

    Enum.join([head | parts], " || '|' || ")
  end

  defp duckdb_serialization(entry) do
    head = "CAST(epoch_us(CAST(r['#{entry.time_column}'] AS timestamptz)) AS text)"

    parts =
      for col <- checksum_columns(entry) do
        case column_type(entry, col) do
          "double precision" ->
            "coalesce(CAST(CAST(floor(CAST(r['#{col}'] AS float8) * 1000000) AS bigint) AS text), '')"

          _ ->
            "coalesce(CAST(r['#{col}'] AS text), '')"
        end
      end

    Enum.join([head | parts], " || '|' || ")
  end

  defp column_type(entry, name) do
    Enum.find_value(entry.columns, fn {n, type, _cast} -> n == name && type end)
  end
end
