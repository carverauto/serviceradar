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
          "site_code" => "ZZC",
          "ap_count" => 17,
          "latitude" => 11.0000,
          "active" => false
        }
      ])

    assert {:ok, payload} =
             Native.encode_arrow_json(["site_code", "ap_count", "latitude", "active"], rows)

    assert <<"ARROW1", _::binary>> = payload
  end

  test "rejects invalid row JSON" do
    assert {:error, reason} = Native.encode_arrow_json(["site_code"], "{")
    assert reason =~ "invalid rows JSON"
  end
end
