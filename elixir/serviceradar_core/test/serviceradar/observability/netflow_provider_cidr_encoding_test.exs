defmodule ServiceRadar.Observability.NetflowProviderCidrEncodingTest do
  @moduledoc """
  Provider CIDR rows must reach `insert_all` in primary-key order.

  The operator-facing 2.4MB/row figure is what `pg_total_relation_size / n_live_tup`
  reads when snapshot rotation bloats a `snapshot_id`-leading btree: every promoted
  snapshot appends a fresh key range and the pruned one leaves holes behind. The PK
  now leads with `cidr`, which only compacts if the writer emits rows in that order.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.NetflowProviderDatasetRefreshWorker

  test "sorts rows into cidr then provider order for packed btree inserts" do
    v4_24 = %Postgrex.INET{address: {192, 0, 2, 0}, netmask: 24}
    v4_25 = %Postgrex.INET{address: {192, 0, 2, 128}, netmask: 25}
    v6_32 = %Postgrex.INET{address: {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0}, netmask: 32}

    sorted =
      NetflowProviderDatasetRefreshWorker.sort_provider_rows([
        %{cidr: v6_32, provider: "aws"},
        %{cidr: v4_25, provider: "cloudflare"},
        %{cidr: v4_24, provider: "azure"},
        %{cidr: v4_24, provider: "aws"}
      ])

    assert Enum.map(sorted, &{&1.cidr, &1.provider}) == [
             {v4_24, "aws"},
             {v4_24, "azure"},
             {v4_25, "cloudflare"},
             {v6_32, "aws"}
           ]
  end
end
