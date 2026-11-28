defmodule Palisade.Plug.RateLimitTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Palisade.Plug.RateLimit

  defmodule DenyAll do
    @behaviour Palisade.RateLimit

    @impl true
    def check(_key, _limit, _window_ms, opts),
      do: {:deny, Keyword.get(opts, :retry_after_ms, 1500)}
  end

  setup context do
    name = :"#{inspect(__MODULE__)}.#{context.test}"
    start_supervised!({Palisade.RateLimit.ETS, name: name})
    %{backend: {Palisade.RateLimit.ETS, name: name}}
  end

  defp request(ip, headers \\ []) do
    Enum.reduce(headers, %{conn(:get, "/login") | remote_ip: ip}, fn {k, v}, conn ->
      put_req_header(conn, k, v)
    end)
  end

  defp plug(opts),
    do: RateLimit.init(Keyword.merge([bucket: :login, limit: 2, window_ms: 60_000], opts))

  test "passes requests under the limit with rate-limit headers", %{backend: backend} do
    conn = RateLimit.call(request({203, 0, 113, 1}), plug(backend: backend))

    refute conn.halted
    assert get_resp_header(conn, "x-ratelimit-limit") == ["2"]
    assert get_resp_header(conn, "x-ratelimit-remaining") == ["1"]
    assert [reset] = get_resp_header(conn, "x-ratelimit-reset")
    assert String.to_integer(reset) >= System.system_time(:second)
  end

  test "denies with 429 and retry-after, without affecting other clients", %{backend: backend} do
    opts = plug(backend: backend)

    for _ <- 1..2, do: refute(RateLimit.call(request({203, 0, 113, 1}), opts).halted)

    denied = RateLimit.call(request({203, 0, 113, 1}), opts)

    assert denied.halted
    assert denied.status == 429
    assert [retry_after] = get_resp_header(denied, "retry-after")
    assert String.to_integer(retry_after) >= 1
    assert get_resp_header(denied, "x-ratelimit-remaining") == ["0"]
    assert denied.resp_body == ~s({"error":"rate_limited","retry_after":#{retry_after}})
    assert get_resp_header(denied, "content-type") == ["application/json; charset=utf-8"]

    refute RateLimit.call(request({203, 0, 113, 2}), opts).halted
  end

  test "buckets are independent", %{backend: backend} do
    login = plug(backend: backend, limit: 1)
    search = plug(backend: backend, limit: 1, bucket: :search)

    refute RateLimit.call(request({203, 0, 113, 1}), login).halted
    assert RateLimit.call(request({203, 0, 113, 1}), login).halted
    refute RateLimit.call(request({203, 0, 113, 1}), search).halted
  end

  test "a spoofed forwarding header from an untrusted peer does not change the key", %{
    backend: backend
  } do
    opts = plug(backend: backend, limit: 1, client_ip: [trusted_proxies: ["10.0.0.0/8"]])

    refute RateLimit.call(request({198, 51, 100, 7}, [{"x-forwarded-for", "1.1.1.1"}]), opts).halted

    assert RateLimit.call(request({198, 51, 100, 7}, [{"x-forwarded-for", "2.2.2.2"}]), opts).halted
  end

  test "clients behind a trusted proxy are keyed by their own address", %{backend: backend} do
    opts = plug(backend: backend, limit: 1, client_ip: [trusted_proxies: ["10.0.0.0/8"]])

    refute RateLimit.call(request({10, 0, 0, 2}, [{"x-forwarded-for", "203.0.113.1"}]), opts).halted

    refute RateLimit.call(request({10, 0, 0, 2}, [{"x-forwarded-for", "203.0.113.2"}]), opts).halted

    assert RateLimit.call(request({10, 0, 0, 2}, [{"x-forwarded-for", "203.0.113.1"}]), opts).halted
  end

  test "a custom key function scopes the limit, falling back to the address on nil", %{
    backend: backend
  } do
    key = fn conn -> conn.assigns[:user_id] end
    opts = plug(backend: backend, limit: 1, key: key)

    as_user = fn ip, id -> assign(request(ip), :user_id, id) end

    refute RateLimit.call(as_user.({203, 0, 113, 1}, "u1"), opts).halted
    assert RateLimit.call(as_user.({203, 0, 113, 2}, "u1"), opts).halted
    refute RateLimit.call(as_user.({203, 0, 113, 2}, "u2"), opts).halted

    refute RateLimit.call(request({203, 0, 113, 3}), opts).halted
    assert RateLimit.call(request({203, 0, 113, 3}), opts).halted
  end

  describe "denied responses" do
    test "HTML when the client accepts it" do
      conn =
        RateLimit.call(
          request({203, 0, 113, 1}, [{"accept", "text/html"}]),
          plug(backend: DenyAll)
        )

      assert conn.status == 429
      assert get_resp_header(conn, "retry-after") == ["2"]
      assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
      assert conn.resp_body =~ "Too Many Requests"
    end

    test "the response mode can be pinned" do
      conn =
        RateLimit.call(
          request({203, 0, 113, 1}, [{"accept", "text/html"}]),
          plug(backend: DenyAll, response: :json)
        )

      assert conn.resp_body =~ ~s("error":"rate_limited")
    end

    test "on_deny builds a custom response" do
      on_deny = fn conn, retry_after ->
        conn |> put_resp_header("location", "/busy?wait=#{retry_after}") |> send_resp(303, "")
      end

      conn =
        RateLimit.call(request({203, 0, 113, 1}), plug(backend: {DenyAll, []}, on_deny: on_deny))

      assert conn.halted
      assert conn.status == 303
      assert get_resp_header(conn, "location") == ["/busy?wait=2"]
      assert get_resp_header(conn, "retry-after") == ["2"]
    end

    test "on_deny returning an unsent conn gets the default 429" do
      conn =
        RateLimit.call(
          request({203, 0, 113, 1}),
          plug(backend: DenyAll, on_deny: fn conn, _ -> assign(conn, :denied, true) end)
        )

      assert conn.status == 429
      assert conn.assigns.denied
    end
  end

  test "options are validated" do
    assert_raise KeyError, fn -> RateLimit.init(limit: 1, window_ms: 1000) end
    assert_raise ArgumentError, fn -> plug(limit: 0) end
    assert_raise ArgumentError, fn -> plug(response: :xml) end
    assert_raise ArgumentError, fn -> plug(key: :session) end
    assert_raise ArgumentError, fn -> plug(backend: "ets") end
  end
end
