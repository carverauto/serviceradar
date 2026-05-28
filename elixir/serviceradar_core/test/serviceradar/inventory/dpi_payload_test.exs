defmodule ServiceRadar.Inventory.DpiPayloadTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.DpiPayload

  @tag :visibility
  test "normalizes flat DPI metadata into nested protocol payloads" do
    metadata =
      DpiPayload.enrich_metadata(%{
        "dpi.source" => "passive-netprobe",
        "dpi.protocol" => "dns",
        "dpi.dns.count" => "1",
        "dpi.dns.confidence" => "0.920",
        "dpi.dns.last_observed_at" => "2026-05-27T14:30:01Z",
        "dpi.ftp.count" => 2,
        "dpi.ftp.confidence" => 0.75,
        "dpi.ftp.last_observed_at" => "2026-05-27T14:31:02Z"
      })

    assert metadata["dpi"]["dns"] == %{
             "count" => 1,
             "confidence" => 0.92,
             "last_observed_at" => "2026-05-27T14:30:01Z"
           }

    assert metadata["dpi"]["ftp"] == %{
             "count" => 2,
             "confidence" => 0.75,
             "last_observed_at" => "2026-05-27T14:31:02Z"
           }
  end
end
