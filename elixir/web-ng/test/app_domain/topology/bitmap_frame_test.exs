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
      sequence: 9_007_199_254_740_993
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
    assert <<"SRMO", 1, 0, 0::little-16, length::little-32, 9_007_199_254_740_993::little-64, fields::binary>> = frame
    assert byte_size(frame) == length

    payload =
      Enum.reduce(1..7, fields, fn _, <<size::little-16, rest::binary>> ->
        binary_part(rest, size, byte_size(rest) - size)
      end)

    assert <<1, 0, 0::little-32, 0::little-32, 14::little-16, "synthetic-tile", 2::little-16, 1, 1, 3, 3, 0, 2,
             1::little-32, 9001::little-32>> = payload
  end

  test "rejects ambiguous receipt/state/count columns before publishing a view" do
    assert {:error, _} = BitmapFrame.encode(metadata(), [tile(), tile()])
    assert {:error, _} = BitmapFrame.encode(metadata(), [%{tile() | mask: <<0, 1>>}])
    assert {:error, _} = BitmapFrame.encode(metadata(), [%{tile() | counts: <<1::little-32>>}])
    assert {:error, _} = BitmapFrame.encode(metadata(), [%{tile() | availability: <<0, 3>>}])
    assert {:error, _} = BitmapFrame.encode(%{metadata() | dictionary_epoch: ""}, [tile()])
    assert {:error, _} = BitmapFrame.encode(%{metadata() | sequence: -1}, [tile()])
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
  end
end
