defmodule ServiceRadarWebNG.Topology.BitmapFrameTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.BitmapFrame

  @moduletag :db_free

  defp metadata do
    %{
      kind: :baseline,
      dictionary_epoch: "synthetic-dictionary",
      index_epoch: "synthetic-process",
      query_digest: "synthetic-query",
      authority_fingerprint: "synthetic-authority",
      view_digest: "synthetic-view",
      source_revision: "9007199254740993",
      index_revision: "9007199254740995",
      sequence: 9_007_199_254_740_993,
      total: 4_294_967_295
    }
  end

  defp tile do
    %{
      z: 0,
      x: 0,
      y: 0,
      revision: "synthetic-tile",
      mask: <<1, 1>>,
      causal: <<3, 3>>,
      availability: <<0, 2>>,
      counts: <<1::little-32, 9001::little-32>>
    }
  end

  test "encodes native row columns and uint64 sequence without JSON conversion" do
    assert {:ok, frame} = BitmapFrame.encode(metadata(), [tile()])

    assert <<"SRMO", 1, 0, 0::little-16, length::little-32, 9_007_199_254_740_993::little-64, 4_294_967_295::little-32,
             fields::binary>> = frame

    assert byte_size(frame) == length

    assert Base.encode16(:crypto.hash(:sha256, frame), case: :lower) ==
             "e845f7ac68b02c88465d989ff118201ef86a179395e8875a01b56684f9b50107"

    payload =
      Enum.reduce(1..7, fields, fn _, <<size::little-16, rest::binary>> ->
        binary_part(rest, size, byte_size(rest) - size)
      end)

    assert <<0, 1, 0, 0::little-32, 0::little-32, 14::little-16, "synthetic-tile", 2::little-16, 1, 1, 3, 3, 0, 2,
             1::little-32, 9001::little-32>> = payload
  end

  test "attaches sorted prefix versions to the replacement and its reset" do
    sources = %{"synthetic-site" => 1, "synthetic-flow" => 9_007_199_254_740_993}

    assert {:ok, frame} = BitmapFrame.encode(Map.put(metadata(), :prefix_sources, sources), [tile()])

    assert {:ok, reset} =
             BitmapFrame.encode(Map.merge(metadata(), %{kind: :reset, prefix_sources: sources}))

    for binary <- [frame, reset] do
      <<"SRMO", 1, _kind, 0::little-16, _size::little-32, _sequence::little-64, _total::little-32, fields::binary>> =
        binary

      rest =
        Enum.reduce(1..7, fields, fn _, <<size::little-16, rest::binary>> ->
          binary_part(rest, size, byte_size(rest) - size)
        end)

      assert <<2, 14::little-16, "synthetic-flow", 9_007_199_254_740_993::little-64, 14::little-16, "synthetic-site",
               1::little-64, _rest::binary>> = rest
    end

    assert {:error, _} =
             BitmapFrame.encode(Map.put(metadata(), :prefix_sources, Map.new(1..33, &{"s#{&1}", 1})), [tile()])

    assert {:error, _} = BitmapFrame.encode(Map.put(metadata(), :prefix_sources, %{"" => 1}), [tile()])
    assert {:error, _} = BitmapFrame.encode(Map.put(metadata(), :prefix_sources, %{"bad" => -1}), [tile()])

    assert {:error, _} =
             BitmapFrame.encode(
               Map.put(metadata(), :prefix_sources, %{"bad" => 18_446_744_073_709_551_616}),
               [tile()]
             )

    wide =
      Map.new(1..32, fn index ->
        {String.pad_leading(Integer.to_string(index), 128, "0"), 18_446_744_073_709_551_615}
      end)

    assert {:ok, wide_frame} = BitmapFrame.encode(Map.put(metadata(), :prefix_sources, wide), [tile()])
    assert byte_size(wide_frame) <= 262_144

    bmp = "synthetic-" <> <<0xEE, 0x80, 0x80>>
    nonbmp = "synthetic-" <> <<0xF0, 0x90, 0x80, 0x80>>
    bom = <<0xEF, 0xBB, 0xBF>> <> "synthetic"
    bmp_size = byte_size(bmp)
    nonbmp_size = byte_size(nonbmp)
    bom_size = byte_size(bom)

    assert {:ok, ordered} =
             BitmapFrame.encode(Map.put(metadata(), :prefix_sources, %{bmp => 1, nonbmp => 2, bom => 3}), [tile()])

    <<"SRMO", 1, _kind, 0::little-16, _size::little-32, _sequence::little-64, _total::little-32, fields::binary>> =
      ordered

    ordered_rest =
      Enum.reduce(1..7, fields, fn _, <<size::little-16, rest::binary>> ->
        binary_part(rest, size, byte_size(rest) - size)
      end)

    assert <<
             3,
             ^bmp_size::little-16,
             ^bmp::binary,
             1::little-64,
             ^nonbmp_size::little-16,
             ^nonbmp::binary,
             2::little-64,
             ^bom_size::little-16,
             ^bom::binary,
             3::little-64,
             _tiles::binary
           >> = ordered_rest

    bom_only = <<0xEF, 0xBB, 0xBF>>

    assert {:ok, bom_frame} =
             BitmapFrame.encode(Map.put(metadata(), :prefix_sources, %{bom_only => 7}), [tile()])

    <<"SRMO", 1, _kind, 0::little-16, _size::little-32, _sequence::little-64, _total::little-32, bom_fields::binary>> =
      bom_frame

    bom_rest =
      Enum.reduce(1..7, bom_fields, fn _, <<size::little-16, rest::binary>> ->
        binary_part(rest, size, byte_size(rest) - size)
      end)

    assert <<1, 3::little-16, ^bom_only::binary, 7::little-64, _tiles::binary>> = bom_rest
  end

  test "rejects ambiguous receipt/state/count columns before publishing a view" do
    assert {:error, _} = BitmapFrame.encode(metadata(), [tile(), tile()])
    assert {:error, _} = BitmapFrame.encode(metadata(), [%{tile() | mask: <<0, 1>>}])
    assert {:error, _} = BitmapFrame.encode(metadata(), [%{tile() | counts: <<1::little-32>>}])
    assert {:error, _} = BitmapFrame.encode(metadata(), [%{tile() | availability: <<0, 3>>}])
    assert {:error, _} = BitmapFrame.encode(%{metadata() | dictionary_epoch: ""}, [tile()])
    assert {:error, _} = BitmapFrame.encode(%{metadata() | sequence: -1}, [tile()])
    assert {:error, _} = BitmapFrame.encode(%{metadata() | total: -1}, [tile()])
    assert {:error, _} = BitmapFrame.encode(%{metadata() | total: 4_294_967_296}, [tile()])
    assert {:error, _} = BitmapFrame.encode(Map.delete(metadata(), :total), [tile()])
  end

  test "fits every admitted row in one frame and encodes a bounded reset" do
    tiles =
      for x <- 0..63 do
        %{
          z: 6,
          x: x,
          y: 0,
          revision: "synthetic-maximum-receipt",
          mask: :binary.copy(<<1>>, 128),
          causal: :binary.copy(<<3>>, 128),
          availability: :binary.copy(<<2>>, 128),
          counts: :binary.copy(<<1::little-32>>, 128)
        }
      end

    assert {:ok, frame} = BitmapFrame.encode(metadata(), tiles)
    assert byte_size(frame) < 65_536
    assert {:ok, <<"SRMO", 1, 1, _::binary>>} = BitmapFrame.encode(%{metadata() | kind: :reset})
    assert {:error, _} = BitmapFrame.encode(%{metadata() | kind: :reset}, [tile()])
    v2 = Map.put(metadata(), :protocol, 2)
    edges = :binary.copy(<<7::little-32>>, 512)
    assert {:ok, expanded} = BitmapFrame.encode(v2, Enum.map(tiles, &Map.put(&1, :edge_counts, edges)))
    assert <<"SRMO", 2, 0, _::binary>> = expanded
    assert byte_size(expanded) == byte_size(frame) + 64 * (2 + 512 * 4)
    assert byte_size(expanded) <= 262_144
    assert binary_part(expanded, byte_size(expanded) - 2050, 2050) == <<512::little-16, edges::binary>>
    assert {:ok, <<"SRMO", 2, 1, _::binary>>} = BitmapFrame.encode(Map.put(v2, :kind, :reset))

    for bad <- [nil, <<1>>, :binary.copy(<<0::little-32>>, 513)] do
      assert {:error, _} = BitmapFrame.encode(v2, [Map.put(tile(), :edge_counts, bad)])
    end
  end
end
