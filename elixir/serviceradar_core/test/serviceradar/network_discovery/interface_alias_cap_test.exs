defmodule ServiceRadar.NetworkDiscovery.InterfaceAliasCapTest do
  @moduledoc """
  Bounds how many `:interface_ip` rows one device can accumulate.

  Nothing else does: no cap in the writer, no schema constraint, no limit on the
  read action, and the UI renders them in an un-streamed table. A device
  reporting an address per interface would produce a row per interface, and the
  largest switch on farm01 enumerates 239.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor

  defp addrs(n), do: for(i <- 1..n, do: "10.0.#{div(i, 256)}.#{rem(i, 256)}")

  test "a normal device is not truncated" do
    ips = addrs(12)

    assert MapperResultsIngestor.cap_interface_ips(ips, "sr:test") == Enum.sort(ips)
  end

  test "a pathological device is truncated to the cap" do
    capped = MapperResultsIngestor.cap_interface_ips(addrs(239), "sr:big-switch")

    assert length(capped) == 64
  end

  test "the retained subset is stable across runs" do
    # This is the property that matters. An arbitrary subset would differ run to
    # run, so aliases would churn -- created, gone stale, recreated -- which is
    # worse than a smaller stable set. Shuffled input must yield identical output.
    ips = addrs(200)

    a = MapperResultsIngestor.cap_interface_ips(Enum.shuffle(ips), "sr:test")
    b = MapperResultsIngestor.cap_interface_ips(Enum.shuffle(ips), "sr:test")

    assert a == b
    assert a == ips |> Enum.sort() |> Enum.take(64)
  end

  test "output is always sorted, capped or not" do
    small = MapperResultsIngestor.cap_interface_ips(["10.0.0.3", "10.0.0.1"], "sr:test")

    assert small == ["10.0.0.1", "10.0.0.3"]
  end

  test "an empty set is preserved" do
    assert MapperResultsIngestor.cap_interface_ips([], "sr:test") == []
  end

  test "exactly at the cap is not truncated" do
    # Boundary: > vs >=. At exactly 64 nothing should be dropped or logged.
    ips = addrs(64)

    assert length(MapperResultsIngestor.cap_interface_ips(ips, "sr:test")) == 64
  end
end
