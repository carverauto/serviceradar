defmodule ServiceRadar.NetworkConfig.IngestTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkConfig.Ingest

  test "content_hash is stable sha256 hex of the body" do
    body = "interface GigabitEthernet0/1\n ip address 192.0.2.1 255.255.255.0\n"
    hash = Ingest.content_hash(body)
    assert hash == Ingest.content_hash(body)
    assert hash != Ingest.content_hash(body <> "!")
    assert String.length(hash) == 64
    assert hash == String.downcase(hash)
  end

  test "unchanged? is true only when the latest hash matches" do
    hash = Ingest.content_hash("running-config")
    assert Ingest.unchanged?(hash, hash)
    refute Ingest.unchanged?(nil, hash)
    refute Ingest.unchanged?("other", hash)
  end

  test "resume_action replays a revision whose facts never landed" do
    assert Ingest.resume_action([]) == :reproject

    assert Ingest.resume_action([%{if_name: "GigabitEthernet0/1"}]) == :unchanged
  end
end
