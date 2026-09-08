defmodule ServiceRadar.Edge.RawBoundsCorpusTest do
  use ExUnit.Case, async: true

  alias Serviceradar.Edge.V1.EdgeDeliveryFrameV1
  alias Serviceradar.Edge.V1.EdgeRecordClientMessage
  alias ServiceRadar.Edge.WireDecode

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)
  @bounds Path.join(@testdata, "raw_bounds_corpus.txt")
  @relational Path.join(@testdata, "raw_relational_corpus.txt")
  @external_resource @bounds
  @external_resource @relational

  test "all four raw budgets admit N and refuse N+1 before decoding" do
    rows = rows(@bounds)
    assert Enum.count(rows) == 11
    assert MapSet.new(rows, &elem(&1, 1)) == MapSet.new(["record", "frame", "envelope", "client"])

    for {name, boundary, quantity, accepted} <- rows do
      raw = File.read!(Path.join(@testdata, name))
      expected_size = if boundary == "envelope", do: quantity + 1, else: quantity
      assert byte_size(raw) == expected_size, name
      assert_verdict(decode(boundary, raw), accepted, name)
    end

    for {boundary, ceiling} <- [
          {"record", 524_288},
          {"frame", 540_672},
          {"envelope", 16_384},
          {"client", 540_680}
        ] do
      assert {"raw_bound_#{boundary}_#{ceiling}.bin", boundary, ceiling, true} in rows
      assert {"raw_bound_#{boundary}_#{ceiling + 1}.bin", boundary, ceiling + 1, false} in rows
    end
  end

  test "received envelope overhead is bounded independently of canonical size" do
    rows = rows(@relational)
    assert length(rows) == 4

    for {name, boundary, overhead, accepted} <- rows do
      raw = File.read!(Path.join(@testdata, name))

      frame =
        case boundary do
          "frame" ->
            EdgeDeliveryFrameV1.decode(raw)

          "client" ->
            %{payload: {:delivery_frame, frame}} = EdgeRecordClientMessage.decode(raw)
            frame
        end

      assert byte_size(EdgeDeliveryFrameV1.encode(frame)) <= 8
      assert byte_size(raw) < 540_672
      assert overhead in [16_384, 16_385]
      assert accepted == (overhead == 16_384)
      assert_verdict(decode(boundary, raw), accepted, name)
    end
  end

  defp assert_verdict(result, true, name),
    do: assert(match?({:ok, _}, result), "#{name}: #{inspect(result)}")

  defp assert_verdict(result, false, name),
    do: assert(result == {:error, :too_large}, "#{name}: #{inspect(result)}")

  defp decode("record", raw), do: WireDecode.decode_record(raw)
  defp decode("frame", raw), do: WireDecode.decode_frame(raw)
  defp decode("envelope", raw), do: WireDecode.decode_frame(raw)
  defp decode("client", raw), do: WireDecode.decode_client_message(raw)

  defp rows(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [name, boundary, quantity, accepted] = String.split(line)
      {name, boundary, String.to_integer(quantity), accepted == "true"}
    end)
  end
end
