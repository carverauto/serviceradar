defmodule ServiceRadarWebNG.Topology.ScaleHarnessTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.TopologyAtlas
  alias ServiceRadarWebNG.Topology.BitmapFrame
  alias ServiceRadarWebNG.Topology.Scale.Client
  alias ServiceRadarWebNG.Topology.Scale.Fixture
  alias ServiceRadarWebNG.Topology.Scale.Meter

  test "the network consumer rejects stale receipts and inconsistent population totals" do
    metadata = %{
      sequence: 1,
      total: 3,
      dictionary_epoch: "dictionary",
      index_epoch: "index",
      query_digest: "query",
      authority_fingerprint: "authority",
      view_digest: "view",
      source_revision: "source",
      index_revision: "revision"
    }

    tile = %{
      z: 0,
      x: 0,
      y: 0,
      revision: "geometry",
      mask: <<1, 0>>,
      causal: <<3, 3>>,
      availability: <<1, 2>>,
      counts: <<3::little-32, 0::little-32>>
    }

    receipt = %{"z" => 0, "x" => 0, "y" => 0, "revision" => "geometry"}
    {:ok, frame} = BitmapFrame.encode(metadata, [tile])
    assert %{kind: :baseline, total: 3, sequence: 1} = Client.decode(envelope(frame), [receipt])
    assert_raise MatchError, fn -> Client.decode(envelope(frame), [%{receipt | "revision" => "stale"}]) end
    {:ok, inconsistent} = BitmapFrame.encode(%{metadata | total: 4}, [tile])
    assert_raise MatchError, fn -> Client.decode(envelope(inconsistent), [receipt]) end
    assert_raise MatchError, fn -> Client.decode(envelope(frame <> <<0>>), [receipt]) end
  end

  test "synthetic geometry really partitions admitted leaf and aggregate rows" do
    world = Fixture.world("synthetic-acceptance-layout", 8_256)

    for y <- 0..7, x <- 0..7 do
      assert {:ok, tile} = TopologyAtlas.tile(world, 3, x, y)
      assert length(tile.glyphs) == 128
      assert Enum.count(tile.glyphs, &(&1.kind == :device)) == 127
      assert Enum.count(tile.glyphs, &(&1.kind == :aggregate)) == 1
    end
  end

  test "isolated peer VMs load declared harness beams and expose actual Linux RSS" do
    {:ok, peer, _} = :peer.start_link(%{connection: :standard_io, args: [~c"+S", ~c"2:2"]})

    try do
      :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
      {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:elixir])

      for {module, binary} <- Application.fetch_env!(:serviceradar_web_ng, :topology_scale_modules) do
        assert {:module, ^module} = :peer.call(peer, :code, :load_binary, [module, ~c"scale-fixture", binary])
      end

      memory = :peer.call(peer, Meter, :memory, [])
      assert memory.rss > 0
      assert memory.rss_high_water >= memory.rss
      assert memory.native_unavailable == 1
      assert memory.mapping_unavailable == 1
    after
      :peer.stop(peer)
    end
  end

  defp envelope(frame), do: <<0, 1, 14, 16, "1topology:tilesmembership:frame", frame::binary>>
end
