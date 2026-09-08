defmodule ServiceRadar.ColdTier.VerificationTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.ColdTier.Registry
  alias ServiceRadar.ColdTier.Verification

  test "checksum columns fall back to content columns when no unique key exists" do
    flows = Registry.fetch!("ocsf_network_activity")

    assert Verification.checksum_columns(flows) == [
             "src_endpoint_ip",
             "dst_endpoint_ip",
             "bytes_total"
           ]

    logs = Registry.fetch!("logs")
    assert Verification.checksum_columns(logs) == ["id"]
  end

  test "primary and parquet SQL serialize the same logical content" do
    for entry <- Registry.tables() do
      pg = Verification.primary_sql(entry)
      duck = Verification.parquet_sql(entry, "s3://bucket/key.parquet")

      # same aggregate shape
      assert pg =~ "count(*)"
      assert duck =~ "count(*)"
      assert pg =~ "substr(md5("
      assert duck =~ "substr(md5("

      # every checksum column appears in both serializations
      for col <- Verification.checksum_columns(entry) do
        assert pg =~ col
        assert duck =~ col
      end

      # engine-divergent constructs are banned from serializations
      refute pg =~ "hashtext"
      refute pg =~ "round("
      refute duck =~ "round("
    end
  end

  test "float columns are quantized, never rendered as raw text" do
    # ocsf_network_activity has no float checksum columns; construct coverage
    # via timeseries_metrics would need value in the checksum — assert the
    # general rule on any table that has a float checksum column.
    for entry <- Registry.tables() do
      float_cols =
        for {name, "double precision", _} <- entry.columns,
            name in Verification.checksum_columns(entry),
            do: name

      for col <- float_cols do
        assert Verification.primary_sql(entry) =~ ~s{floor("#{col}" * 1000000)}
        assert Verification.parquet_sql(entry, "u") =~ "floor(CAST(r['#{col}'] AS float8)"
      end
    end
  end

  test "results compare on the full pair" do
    a = %{row_count: 10, min_epoch_us: 1, max_epoch_us: 2, checksum: "42"}
    assert Verification.match?(a, a)
    refute Verification.match?(a, %{a | checksum: "43"})
    refute Verification.match?(a, %{a | row_count: 9})
  end
end
