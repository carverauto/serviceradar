defmodule ServiceRadarWebNG.ClientIPTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.ClientIP

  # The unit tier is an ALLOW-LIST (test_helper.exs: exclude: [:test], include: [:db_free]).
  # Without this tag the whole module is loaded and silently excluded -- which is how the
  # three tests below shipped in #366 without ever having run in CI.
  @moduletag :db_free

  setup do
    original = Application.get_env(:serviceradar_web_ng, :client_ip)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:serviceradar_web_ng, :client_ip)
      else
        Application.put_env(:serviceradar_web_ng, :client_ip, original)
      end
    end)

    :ok
  end

  test "uses remote_ip when forwarded headers are disabled" do
    Application.put_env(:serviceradar_web_ng, :client_ip,
      trust_x_forwarded_for: false,
      trusted_proxy_cidrs: ["10.0.0.0/8"]
    )

    conn =
      :get
      |> Plug.Test.conn("/")
      |> Map.put(:remote_ip, {10, 0, 0, 5})
      |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.20")

    assert ClientIP.get(conn) == "10.0.0.5"
  end

  test "uses the rightmost untrusted forwarded hop when behind a trusted proxy" do
    Application.put_env(:serviceradar_web_ng, :client_ip,
      trust_x_forwarded_for: true,
      trusted_proxy_cidrs: ["10.0.0.0/8"]
    )

    conn =
      :get
      |> Plug.Test.conn("/")
      |> Map.put(:remote_ip, {10, 0, 0, 5})
      |> Plug.Conn.put_req_header("x-forwarded-for", "127.0.0.1, 203.0.113.20")

    assert ClientIP.get(conn) == "203.0.113.20"
  end

  test "ignores forwarded headers from untrusted peers" do
    Application.put_env(:serviceradar_web_ng, :client_ip,
      trust_x_forwarded_for: true,
      trusted_proxy_cidrs: ["10.0.0.0/8"]
    )

    conn =
      :get
      |> Plug.Test.conn("/")
      |> Map.put(:remote_ip, {203, 0, 113, 55})
      |> Plug.Conn.put_req_header("x-forwarded-for", "127.0.0.1")

    assert ClientIP.get(conn) == "203.0.113.55"
  end

  test "falls back to the direct peer when every forwarded hop is a trusted proxy" do
    # The chain a LAN client produces behind a single trusted proxy whose trusted CIDRs are
    # too broad: the client's own address is classified as a proxy, so walking right-to-left
    # for the first untrusted hop finds nothing. That must degrade to the peer, not raise --
    # in v1.4.56 it raised FunctionClauseError and every login from the LAN was a 500.
    Application.put_env(:serviceradar_web_ng, :client_ip,
      trust_x_forwarded_for: true,
      trusted_proxy_cidrs: ["10.0.0.0/8", "192.168.0.0/16"]
    )

    conn =
      :get
      |> Plug.Test.conn("/")
      |> Map.put(:remote_ip, {10, 0, 0, 5})
      |> Plug.Conn.put_req_header("x-forwarded-for", "192.168.100.7")

    assert ClientIP.get(conn) == "10.0.0.5"
  end

  test "falls back to the direct peer when the forwarded header is present but empty" do
    Application.put_env(:serviceradar_web_ng, :client_ip,
      trust_x_forwarded_for: true,
      trusted_proxy_cidrs: ["10.0.0.0/8"]
    )

    conn =
      :get
      |> Plug.Test.conn("/")
      |> Map.put(:remote_ip, {10, 0, 0, 5})
      |> Plug.Conn.put_req_header("x-forwarded-for", " , ")

    assert ClientIP.get(conn) == "10.0.0.5"
  end
end
