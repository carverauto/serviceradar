defmodule ServiceRadarWebNG.ClientIPTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.ClientIP

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
end
