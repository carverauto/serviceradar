defmodule ServiceRadar.Observability.ThreatIntelRawPayloadStoreTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.ThreatIntelRawPayloadStore

  test "builds stable sanitized object keys from payload metadata" do
    payload = ~s({"objects":[{"id":"indicator--1"}]})

    key =
      ThreatIntelRawPayloadStore.object_key(
        %{
          source: "alienvault_otx",
          collection_id: "otx:pulses/subscribed",
          observed_at: ~U[2026-04-28 01:02:03Z]
        },
        payload
      )

    assert key ==
             "alienvault_otx/otx:pulses-subscribed/20260428T010203Z-#{ThreatIntelRawPayloadStore.sha256(payload)}.json"
  end
end
