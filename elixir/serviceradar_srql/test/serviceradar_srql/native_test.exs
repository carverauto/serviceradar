defmodule ServiceRadarSRQL.NativeTest do
  use ExUnit.Case, async: true

  alias ServiceRadarSRQL.Native

  test "encodes normalized rows as an Arrow IPC file payload" do
    rows =
      Jason.encode!([
        %{
          "site_code" => "ORD",
          "ap_count" => 42,
          "latitude" => 41.9742,
          "active" => true
        },
        %{
          "site_code" => "DEN",
          "ap_count" => 17,
          "latitude" => 39.8561,
          "active" => false
        }
      ])

    assert {:ok, payload} =
             Native.encode_arrow_json(["site_code", "ap_count", "latitude", "active"], rows)

    assert is_binary(payload)
    assert byte_size(payload) > 0
    assert binary_part(payload, 0, 6) == "ARROW1"
  end

  test "rejects invalid row JSON" do
    assert {:error, reason} = Native.encode_arrow_json(["site_code"], "{")
    assert reason =~ "invalid rows JSON"
  end
end
