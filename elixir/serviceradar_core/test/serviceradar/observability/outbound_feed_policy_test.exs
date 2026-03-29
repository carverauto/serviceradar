defmodule ServiceRadar.Observability.OutboundFeedPolicyTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.OutboundFeedPolicy

  test "rejects private loopback addresses" do
    assert {:error, :disallowed_host} =
             OutboundFeedPolicy.validate("https://127.0.0.1/private-feed.txt")
  end

  test "allows public https addresses" do
    assert :ok = OutboundFeedPolicy.validate("https://1.1.1.1/public-feed.txt")
  end

  test "redacts query strings and userinfo from logged URLs" do
    assert OutboundFeedPolicy.redact_url("https://user:pass@example.com/feed.txt?token=abc123") ==
             "https://example.com/feed.txt"
  end
end
