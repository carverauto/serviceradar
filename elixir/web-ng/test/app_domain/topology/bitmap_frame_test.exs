defmodule ServiceRadarWebNG.Topology.BitmapFrameTest do
  use ExUnit.Case, async: true

  alias Bandit.WebSocket.PerMessageDeflate
  alias Phoenix.Socket.Message
  alias Phoenix.Socket.V2.JSONSerializer
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
  end

  test "Phoenix binary membership survives negotiated deflate with and without context takeover" do
    for distribution <- [:uniform, :mixed], takeover <- [false, true] do
      params = if takeover, do: [], else: [{"server_no_context_takeover", true}]
      {context, extensions} = PerMessageDeflate.negotiate([{"permessage-deflate", params}], [])
      assert [{:"permessage-deflate", _}] = extensions
      inflater = :zlib.open()
      :ok = :zlib.inflateInit(inflater, -15)

      try do
        tiles = compression_tiles(distribution)

        samples =
          for sequence <- 1..100 do
            assert {:ok, frame} = BitmapFrame.encode(%{metadata() | sequence: sequence}, tiles)

            assert {:socket_push, :binary, wire} =
                     JSONSerializer.encode!(%Message{
                       topic: "topology:tiles",
                       event: "membership:frame",
                       join_ref: "1",
                       payload: {:binary, frame}
                     })

            assert <<0, 1, 14, 16, "1topology:tilesmembership:frame", ^frame::binary>> = wire
            {micros, {:ok, compressed, _context}} = :timer.tc(fn -> PerMessageDeflate.deflate(wire, context) end)
            assert IO.iodata_to_binary(:zlib.inflate(inflater, <<compressed::binary, 0, 0, 255, 255>>)) == wire
            if !takeover, do: :zlib.inflateReset(inflater)
            {micros, byte_size(compressed), byte_size(wire)}
          end

        times = samples |> Enum.drop(10) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
        sizes = Enum.map(samples, &elem(&1, 1))

        IO.puts(
          "ATLAS_MEMBERSHIP_DEFLATE " <>
            Jason.encode!(%{
              distribution: distribution,
              context_takeover: takeover,
              samples: length(samples),
              wire_bytes: elem(hd(samples), 2),
              first_bytes: hd(sizes),
              maximum_bytes: Enum.max(sizes),
              minimum_bytes: Enum.min(sizes),
              deflate_p95_us: Enum.at(times, 85)
            })
        )
      after
        :zlib.close(inflater)
        PerMessageDeflate.close(context)
      end
    end
  end

  defp compression_tiles(distribution) do
    for x <- 0..63 do
      counts =
        for row <- 0..127 do
          if distribution == :uniform, do: 1, else: :erlang.phash2({x, row}, 65_536)
        end

      %{
        z: 6,
        x: x,
        y: 0,
        revision: "synthetic-compression-receipt-#{x}",
        mask: :erlang.list_to_binary(Enum.map(counts, &if(&1 > 0, do: 1, else: 0))),
        causal: :binary.copy(<<3>>, 128),
        availability: :erlang.list_to_binary(Enum.map(counts, &rem(&1, 3))),
        counts: IO.iodata_to_binary(Enum.map(counts, &<<&1::little-32>>))
      }
    end
  end
end
