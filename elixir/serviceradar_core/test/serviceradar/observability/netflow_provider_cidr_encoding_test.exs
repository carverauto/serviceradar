defmodule ServiceRadar.Observability.NetflowProviderCidrEncodingTest do
  @moduledoc """
  Provider CIDR rows must stay one compact prefix each.

  The operator-facing 2.4MB/row figure is what `pg_total_relation_size / n_live_tup`
  reads when snapshot-rotation bloats the `(snapshot_id, cidr, provider)` btree;
  concatenating one provider's prefixes into a single field is the same order of
  magnitude (AWS compact JSON is ~2.3MB). Encoding must reject that blob and emit
  one CIDR per row, sorted for the `(cidr, provider, snapshot_id)` PK.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.NetflowProviderDatasetRefreshWorker
  alias ServiceRadar.Types.Cidr

  # Stay under 1KiB even with ETF overhead; live heap rows measured 72–328B.
  @max_persisted_row_bytes 1024

  test "emits one compact row per CIDR instead of a per-provider blob" do
    input =
      for i <- 0..199 do
        %{
          "cidr" => "192.0.2.#{i}/32",
          "provider" => "aws",
          "service" => "ec2",
          "region" => "us-east-1",
          "ip_version" => "IPv4"
        }
      end

    rows = NetflowProviderDatasetRefreshWorker.encode_provider_rows(input)

    assert length(rows) == 200

    sizes = Enum.map(rows, &NetflowProviderDatasetRefreshWorker.persisted_row_byte_size/1)
    assert Enum.max(sizes) < @max_persisted_row_bytes
    assert Enum.sum(sizes) < 200 * @max_persisted_row_bytes

    # Concatenating the same prefixes into one field is the 2.4MB failure mode.
    blob_size = byte_size(Jason.encode!(Enum.map(input, & &1["cidr"])))
    assert blob_size > @max_persisted_row_bytes
    refute Enum.any?(sizes, &(&1 >= blob_size))
  end

  test "drops a multi-megabyte cidr field instead of persisting it as a row" do
    blob = String.duplicate("x", 2_400_000)

    assert byte_size(blob) == 2_400_000

    assert [] =
             NetflowProviderDatasetRefreshWorker.encode_provider_rows([
               %{"cidr" => blob, "provider" => "aws", "ip_version" => "IPv4"}
             ])
  end

  test "sorts rows into cidr then provider order for packed btree inserts" do
    rows =
      NetflowProviderDatasetRefreshWorker.encode_provider_rows([
        %{"cidr" => "192.0.2.128/25", "provider" => "cloudflare"},
        %{"cidr" => "192.0.2.0/24", "provider" => "aws"},
        %{"cidr" => "192.0.2.0/24", "provider" => "azure"}
      ])

    assert Enum.map(rows, &{cidr_string(&1.cidr), &1.provider}) == [
             {"192.0.2.0/24", "aws"},
             {"192.0.2.0/24", "azure"},
             {"192.0.2.128/25", "cloudflare"}
           ]
  end

  test "dedupes the same CIDR and provider to a single row" do
    rows =
      NetflowProviderDatasetRefreshWorker.encode_provider_rows([
        %{"cidr" => "192.0.2.0/24", "provider" => "AWS", "service" => "ec2"},
        %{"cidr" => "192.0.2.0/24", "provider" => "aws", "service" => "s3"}
      ])

    assert length(rows) == 1
    assert hd(rows).provider == "aws"
  end

  defp cidr_string(value) do
    assert {:ok, string} = Cidr.cast_stored(value, [])
    string
  end
end
