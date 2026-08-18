defmodule ServiceRadarWebNGWeb.Api.RawBodyReaderTest do
  @moduledoc """
  Which paths get their request bytes buffered.

  This matters more than it looks. An unregistered prefix does not fail loudly:
  `raw_body/1` returns `""`, the caller falls back to a re-encoded body, and the
  HMAC comparison silently starts failing for exactly the providers that sign
  bytes. So registration is asserted here rather than described in prose
  (tasks 1.6.4 and 1.6.4a).
  """

  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Api.RawBodyReader

  @northbound_prefix "/api/northbound/action-callbacks/"
  @notification_prefix "/api/notifications/callbacks/"

  test "captures exact northbound callback body bytes" do
    body = ~s({"status":"succeeded","result":{"message":"ok"}})
    conn = Plug.Test.conn("POST", @northbound_prefix <> "job-1", body)

    assert {:ok, ^body, conn} = RawBodyReader.read_body(conn, [])
    assert RawBodyReader.raw_body(conn) == body
  end

  test "captures exact notification callback body bytes" do
    # Deliberately not what `Jason.encode!` would emit for the decoded map:
    # duplicate-free but with padding whitespace and non-alphabetical keys, so a
    # re-encoded body would not compare equal.
    body = ~s({ "type" : "block_actions",\n  "actions" : [ {"action_id":"ack"} ] })
    conn = Plug.Test.conn("POST", @notification_prefix <> "slack", body)

    assert {:ok, ^body, conn} = RawBodyReader.read_body(conn, [])
    assert RawBodyReader.raw_body(conn) == body
  end

  test "does not retain raw bodies for unrelated API paths" do
    conn = Plug.Test.conn("POST", "/api/other", ~s({"status":"ignored"}))

    assert {:ok, _body, conn} = RawBodyReader.read_body(conn, [])
    assert RawBodyReader.raw_body(conn) == ""
  end

  test "does not retain raw bodies for the sibling notification action route" do
    # `/api/notifications/actions/` is a capability link, not a signed callback.
    # Buffering it would keep a live credential in `conn.private` for no reason.
    conn = Plug.Test.conn("POST", "/api/notifications/actions/srn1.abc.def", "")

    assert {:ok, _body, conn} = RawBodyReader.read_body(conn, [])
    assert RawBodyReader.raw_body(conn) == ""
  end

  test "both callback prefixes are registered and nothing else is" do
    assert RawBodyReader.callback_prefixes() == [@northbound_prefix, @notification_prefix]

    assert RawBodyReader.buffered?(@northbound_prefix <> "job-1")
    assert RawBodyReader.buffered?(@notification_prefix <> "pagerduty")

    refute RawBodyReader.buffered?("/api/notifications/actions/srn1.abc.def")
    refute RawBodyReader.buffered?("/api/northbound/action-callbacks")
    refute RawBodyReader.buffered?("/api/other")
    refute RawBodyReader.buffered?(nil)
  end

  test "chunked reads reassemble in order" do
    first = ~s({"a":1,)
    second = ~s("b":2})

    conn = Plug.Test.conn("POST", @notification_prefix <> "webhook", first <> second)

    assert {:more, ^first, conn} = RawBodyReader.read_body(conn, length: byte_size(first))
    assert {:ok, ^second, conn} = RawBodyReader.read_body(conn, [])
    assert RawBodyReader.raw_body(conn) == first <> second
  end
end
