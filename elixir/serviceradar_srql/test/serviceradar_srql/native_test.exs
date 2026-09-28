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

  describe "translate with a permitted-signal set" do
    test "translate/5 supplies no set, so otel_services fails closed" do
      assert {:error, "forbidden: " <> _} =
               Native.translate("in:otel_services", 50, nil, nil, nil)
    end

    test "translate/6 narrows otel_services to the permitted signals" do
      assert {:ok, json} = Native.translate("in:otel_services", 50, nil, nil, nil, ["logs"])
      assert %{"sql" => sql} = Jason.decode!(json)
      assert sql =~ "logs_last_seen_at AS last_seen"
      refute sql =~ "traces_last_seen_at"
    end

    test "translate/6 rejects a signal outside the set as forbidden" do
      assert {:error, "forbidden: " <> _} =
               Native.translate("in:otel_services signal:traces", 50, nil, nil, nil, ["logs"])
    end

    test "translate/6 reports a malformed signal filter as an invalid request" do
      assert {:error, "invalid request: " <> _} =
               Native.translate("in:otel_services !signal:logs", 50, nil, nil, nil, ["logs"])
    end

    test "translate/5 is unchanged for other entities" do
      assert {:ok, _json} = Native.translate("in:services", 10, nil, nil, nil)
    end
  end

  test "rejects invalid row JSON" do
    assert {:error, reason} = Native.encode_arrow_json(["site_code"], "{")
    assert reason =~ "invalid rows JSON"
  end
end
