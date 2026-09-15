defmodule ServiceRadar.AnalyticsStore.BindingsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore.Bindings

  test "replaces whole parameter numbers and repeated references" do
    assert {:ok, "SELECT CAST(1 AS bigint), CAST(10 AS bigint), CAST(1 AS bigint)"} =
             Bindings.bind("SELECT $1, $10, $1", Enum.to_list(1..10))
  end

  test "never replaces parameter-like text inside SQL values or identifiers" do
    sql = ~S[SELECT '$1', E'it\'s $1', "$1", $$ $1 $$, $body$ $1 $body$, device$1, $1]

    assert {:ok, result} = Bindings.bind(sql, [7])

    assert result ==
             ~S[SELECT '$1', E'it\'s $1', "$1", $$ $1 $$, $body$ $1 $body$, device$1, CAST(7 AS bigint)]
  end

  test "keeps ordinary backslashes and doubled SQL quotes intact" do
    sql = ~S[SELECT '\', 'it''s $1', "a""$1", $1]
    assert {:ok, result} = Bindings.bind(sql, [true])
    assert result == ~S[SELECT '\', 'it''s $1', "a""$1", TRUE]
  end

  test "does not rewrite line comments or nested block comments" do
    sql = "SELECT $1 /* $1 /* $2 */ $3 */ -- $4\n, $1 -- trailing $2"

    assert {:ok, "SELECT TRUE /* $1 /* $2 */ $3 */ -- $4\n, TRUE -- trailing $2"} =
             Bindings.bind(sql, [true])
  end

  test "text uses escape strings with quotes and backslashes escaped separately" do
    value = "synthetic\\'; SELECT $2; --"

    assert {:ok, result} = Bindings.bind("SELECT $1", [value])
    assert result == ~S[SELECT CAST(E'synthetic\\''; SELECT $2; --' AS text)]

    assert {:ok, ^result} = Bindings.bind(result, [])
  end

  test "renders primitive scalar types and untyped null" do
    assert {:ok, "SELECT TRUE, FALSE, CAST(-2 AS bigint), CAST(1.5 AS float8), NULL"} =
             Bindings.bind("SELECT $1, $2, $3, $4, $5", [true, false, -2, 1.5, nil])
  end

  test "renders timestamps dates and decimals without losing precision" do
    params = [
      ~D[2000-01-02],
      ~U[2000-01-02 03:04:05.123456Z],
      ~N[2000-01-02 03:04:05.123456],
      Decimal.new("12.34567890123456789")
    ]

    assert {:ok, sql} = Bindings.bind("SELECT $1, $2, $3, $4", params)
    assert sql =~ "DATE '2000-01-02'"
    assert sql =~ "TIMESTAMPTZ '2000-01-02T03:04:05.123456Z'"
    assert sql =~ "TIMESTAMP '2000-01-02T03:04:05.123456'"
    assert sql =~ "CAST('12.34567890123456789' AS numeric)"
  end

  test "typed empty arrays and binary UUIDs retain their SRQL types" do
    uuid = "00000000-0000-4000-8000-000000000001"
    {:ok, binary_uuid} = Ecto.UUID.dump(uuid)

    assert {:ok, sql} =
             Bindings.bind("SELECT $1, $2, $3, $4", [[], [], binary_uuid, nil],
               types: ["int_array", "text_array", "uuid", "int"]
             )

    assert sql ==
             "SELECT CAST(ARRAY[] AS bigint[]), CAST(ARRAY[] AS text[]), " <>
               "CAST('#{uuid}' AS uuid), CAST(NULL AS bigint)"
  end

  test "renders homogeneous arrays including null elements" do
    assert {:ok, sql} = Bindings.bind("SELECT $1, $2", [[nil, "synthetic"], [1, 2]])

    assert sql ==
             "SELECT CAST(ARRAY[CAST(NULL AS text), CAST(E'synthetic' AS text)] AS text[]), " <>
               "CAST(ARRAY[CAST(1 AS bigint), CAST(2 AS bigint)] AS bigint[])"
  end

  test "rejects unsupported values and mismatched type hints without returning their contents" do
    for value <- [%{secret: "synthetic"}, :unsupported, <<255>>, <<0>>, [[1]], [1, "two"]] do
      assert {:error, :invalid_analytics_parameter} = Bindings.bind("SELECT $1", [value])
    end

    for value <- [Decimal.new("NaN"), Decimal.new("Infinity")] do
      assert {:error, :invalid_analytics_parameter} = Bindings.bind("SELECT $1", [value])
    end

    assert {:error, :invalid_analytics_parameter} =
             Bindings.bind("SELECT $1", ["synthetic"], types: ["int"])

    assert {:error, :invalid_analytics_parameter} =
             Bindings.bind("SELECT $1", [1], types: ["unknown"])

    assert {:error, :invalid_analytics_parameter} =
             Bindings.bind("SELECT $1", [1], types: ["int", "int"])
  end

  test "rejects missing or invalid placeholder numbers" do
    for sql <- ["SELECT $0", "SELECT $2", "SELECT $10"] do
      assert {:error, :invalid_analytics_placeholder} = Bindings.bind(sql, [1])
    end
  end

  test "rejects unterminated strings identifiers dollar quotes and comments" do
    for sql <- ["SELECT '$1", ~S[SELECT E'\'], ~S[SELECT "$1], "SELECT $$ $1", "/* $1"] do
      assert {:error, :invalid_analytics_sql} = Bindings.bind(sql, [1])
    end
  end

  test "code transformations can include quoted identifiers without touching values" do
    sql = ~s[SELECT 'platform."metrics"', $$platform."metrics"$$ FROM platform."metrics"]

    assert {:ok, rewritten} =
             Bindings.map_sql(
               sql,
               fn code -> {:ok, String.replace(code, ~s[platform."metrics"], ~s["metrics"])} end,
               quoted_identifiers: :code
             )

    assert rewritten == ~s[SELECT 'platform."metrics"', $$platform."metrics"$$ FROM "metrics"]
  end
end
