defmodule Palisade.ClientIPTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Plug.Conn
  import Plug.Test

  alias Palisade.ClientIP
  alias Palisade.Plug.RemoteIP

  @proxy {10, 0, 0, 2}
  @trusted [trusted_proxies: ["10.0.0.0/8"]]

  defp request(peer, forwarded \\ []) do
    Enum.reduce(forwarded, %{conn(:get, "/") | remote_ip: peer}, fn value, conn ->
      %{conn | req_headers: conn.req_headers ++ [{"x-forwarded-for", value}]}
    end)
  end

  describe "untrusted peers" do
    test "a forwarding header from a peer outside the trusted CIDRs is ignored" do
      peer = {198, 51, 100, 7}
      assert ClientIP.from_conn(request(peer, ["203.0.113.9"]), @trusted) == peer
    end

    test "the header is never read when no proxies are trusted" do
      assert ClientIP.from_conn(request(@proxy, ["203.0.113.9"])) == @proxy
    end

    property "an untrusted peer always resolves to itself, whatever it forwards" do
      check all(
              peer <- tuple({integer(11..223), integer(0..255), integer(0..255), integer(1..254)}),
              values <- list_of(string(:printable, max_length: 64), max_length: 3)
            ) do
        assert ClientIP.resolve(peer, values, @trusted) == peer
      end
    end
  end

  describe "trusted proxies" do
    test "the rightmost untrusted address is the client" do
      conn = request(@proxy, ["198.51.100.1, 203.0.113.9, 10.0.0.9"])
      assert ClientIP.from_conn(conn, @trusted) == {203, 0, 113, 9}
    end

    test "addresses a client prepends cannot displace the one the proxy appended" do
      # The client sent "1.1.1.1"; the proxy appended the client's real address.
      conn = request(@proxy, ["1.1.1.1", "203.0.113.9"])
      assert ClientIP.from_conn(conn, @trusted) == {203, 0, 113, 9}
    end

    test "ports and bracketed IPv6 entries are accepted" do
      assert ClientIP.resolve(@proxy, ["203.0.113.9:4711"], @trusted) == {203, 0, 113, 9}

      assert ClientIP.resolve(@proxy, ["[2001:db8::1]:443"], @trusted) ==
               {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}

      assert ClientIP.resolve(@proxy, ["2001:db8::1"], @trusted) ==
               {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
    end

    test "an IPv4-mapped client or peer resolves to the IPv4 address" do
      assert ClientIP.resolve(@proxy, ["::ffff:203.0.113.9"], @trusted) == {203, 0, 113, 9}

      mapped_proxy = {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0002}
      assert ClientIP.resolve(mapped_proxy, ["203.0.113.9"], @trusted) == {203, 0, 113, 9}
    end

    test "falls back to the peer when every hop is trusted" do
      assert ClientIP.resolve(@proxy, ["10.1.1.1, 10.2.2.2"], @trusted) == @proxy
    end

    test "falls back to the peer at a malformed entry before an untrusted address" do
      assert ClientIP.resolve(@proxy, ["203.0.113.9, unknown"], @trusted) == @proxy
      assert ClientIP.resolve(@proxy, ["203.0.113.9:port"], @trusted) == @proxy
      assert ClientIP.resolve(@proxy, ["203.0.113"], @trusted) == @proxy
    end
  end

  describe "bounds" do
    test "an oversized header is ignored" do
      padding = String.duplicate("1.1.1.1, ", 200)
      assert ClientIP.resolve(@proxy, [padding <> "203.0.113.9"], @trusted) == @proxy
    end

    test "too many addresses are ignored" do
      chain = Enum.map_join(1..17, ",", fn n -> "203.0.113.#{n}" end)
      assert ClientIP.resolve(@proxy, [chain], @trusted) == @proxy

      chain = Enum.map_join(1..16, ",", fn n -> "203.0.113.#{n}" end)
      assert ClientIP.resolve(@proxy, [chain], @trusted) == {203, 0, 113, 16}
    end

    test "too many header lines are ignored" do
      values = List.duplicate("203.0.113.9", 5)
      assert ClientIP.resolve(@proxy, values, @trusted) == @proxy
      assert ClientIP.resolve(@proxy, Enum.take(values, 4), @trusted) == {203, 0, 113, 9}
    end

    test "bounds are configurable" do
      opts = @trusted ++ [max_header_bytes: 8]
      assert ClientIP.resolve(@proxy, ["203.0.113.9"], opts) == @proxy
    end
  end

  describe "options" do
    test "are validated" do
      assert_raise ArgumentError, fn -> ClientIP.new(trusted_proxies: ["10.0.0.0"]) end
      assert_raise ArgumentError, fn -> ClientIP.new(trusted_proxies: ["10.0.0.0/33"]) end
      assert_raise ArgumentError, fn -> ClientIP.new(trusted_proxies: "10.0.0.0/8") end
      assert_raise ArgumentError, fn -> ClientIP.new(max_addresses: 0) end
      assert_raise ArgumentError, fn -> ClientIP.new(header: "X-Real-IP") end
      assert_raise KeyError, fn -> ClientIP.new(trust_everything: true) end
    end

    test "a custom header name is honored" do
      conn = put_req_header(request(@proxy), "x-real-ip", "203.0.113.9")
      assert ClientIP.from_conn(conn, @trusted ++ [header: "x-real-ip"]) == {203, 0, 113, 9}
    end
  end

  describe "from_connect_info/2" do
    test "resolves like a conn" do
      info = %{
        peer_data: %{address: @proxy, port: 4000, ssl_cert: nil},
        x_headers: [{"x-forwarded-for", "203.0.113.9"}]
      }

      assert ClientIP.from_connect_info(info, @trusted) == {203, 0, 113, 9}
      assert ClientIP.from_connect_info(info) == @proxy
    end

    test "ignores forwarding headers from an untrusted peer" do
      info = [
        peer_data: %{address: {198, 51, 100, 7}},
        x_headers: [{"x-forwarded-for", "203.0.113.9"}]
      ]

      assert ClientIP.from_connect_info(info, @trusted) == {198, 51, 100, 7}
    end

    test "returns nil without peer data" do
      assert ClientIP.from_connect_info(%{}, @trusted) == nil
      assert ClientIP.from_connect_info(nil, @trusted) == nil
    end
  end

  describe "Palisade.Plug.RemoteIP" do
    test "rewrites remote_ip and keeps the socket peer" do
      conn = RemoteIP.call(request(@proxy, ["203.0.113.9"]), RemoteIP.init(@trusted))

      assert conn.remote_ip == {203, 0, 113, 9}
      assert conn.private[:palisade_peer_ip] == @proxy
      assert ClientIP.from_conn(conn, @trusted) == {203, 0, 113, 9}
    end

    test "leaves an untrusted peer alone" do
      peer = {198, 51, 100, 7}
      conn = RemoteIP.call(request(peer, ["203.0.113.9"]), RemoteIP.init(@trusted))
      assert conn.remote_ip == peer
    end

    test "does not resolve twice" do
      opts = RemoteIP.init(trusted_proxies: ["10.0.0.0/8", "203.0.113.0/24"])
      once = RemoteIP.call(request(@proxy, ["198.51.100.1, 203.0.113.9"]), opts)
      assert once.remote_ip == {198, 51, 100, 1}
      assert RemoteIP.call(once, opts) == once
    end
  end

  test "format/1 renders both families" do
    assert ClientIP.format({203, 0, 113, 9}) == "203.0.113.9"
    assert ClientIP.format({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}) == "2001:db8::1"
  end
end
