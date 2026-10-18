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
    bmp = "synthetic-" <> <<0xEE, 0x80, 0x80>>
    nonbmp = "synthetic-" <> <<0xF0, 0x90, 0x80, 0x80>>
    bom = <<0xEF, 0xBB, 0xBF>> <> "synthetic"
    sources = %{bmp => 1, nonbmp => 2, bom => 3, <<0xEF, 0xBB, 0xBF>> => 4}
    metadata = Map.put(metadata, :prefix_sources, sources)
    {:ok, frame} = BitmapFrame.encode(metadata, [tile])
    assert %{kind: :baseline, total: 3, sequence: 1} = Client.decode(envelope(frame), [receipt])
    {:ok, reset} = BitmapFrame.encode(Map.put(metadata, :kind, :reset), [])
    assert %{kind: :reset, sequence: 1} = Client.decode(envelope(reset), [])
    assert_raise MatchError, fn -> Client.decode(envelope(reverse_sources(frame)), [receipt]) end
    assert_raise MatchError, fn -> Client.decode(envelope(frame), [%{receipt | "revision" => "stale"}]) end
    {:ok, inconsistent} = BitmapFrame.encode(%{metadata | total: 4}, [tile])
    assert_raise MatchError, fn -> Client.decode(envelope(inconsistent), [receipt]) end
    assert_raise MatchError, fn -> Client.decode(envelope(frame <> <<0>>), [receipt]) end
  end

  test "only a churning normal viewer must show fresh progress within 30 seconds" do
    silent_since = System.monotonic_time(:millisecond) - 31_000
    stats = %{last_fresh_at: nil, max_normal_gap_ms: 0}
    viewer = %{slow: false, phase: :steady, phase_since: silent_since, stats: stats}

    assert {:noreply, %{stats: %{max_normal_gap_ms: 0}}} = Client.handle_info(:progress, viewer)
    assert_receive :progress, 2_000

    assert_raise RuntimeError, ~r/no accepted progress/, fn ->
      Client.handle_info(:progress, %{viewer | phase: :churn})
    end

    assert_receive :progress, 2_000
    fresh = %{viewer | phase: :churn, stats: %{stats | last_fresh_at: System.monotonic_time(:millisecond)}}
    assert {:noreply, %{stats: %{max_normal_gap_ms: gap}}} = Client.handle_info(:progress, fresh)
    assert gap < 30_000
    assert_receive :progress, 2_000
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

  defp reverse_sources(frame) do
    <<"SRMO", 1, kind, 0::little-16, size::little-32, sequence::little-64, total::little-32, rest::binary>> = frame
    {prefix, rest} = drop_texts(rest, 7)
    <<count, rest::binary>> = rest

    <<len1::little-16, first::binary-size(len1), ver1::binary-size(8), len2::little-16, second::binary-size(len2),
      ver2::binary-size(8), rest::binary>> = rest

    <<
      "SRMO",
      1,
      kind,
      0::little-16,
      size::little-32,
      sequence::little-64,
      total::little-32,
      prefix::binary,
      count,
      len2::little-16,
      second::binary,
      ver2::binary,
      len1::little-16,
      first::binary,
      ver1::binary,
      rest::binary
    >>
  end

  defp drop_texts(rest, 0), do: {"", rest}

  defp drop_texts(<<length::little-16, rest::binary>>, count) do
    <<value::binary-size(length), rest::binary>> = rest
    {tail, rest} = drop_texts(rest, count - 1)
    {<<length::little-16, value::binary, tail::binary>>, rest}
  end
end
