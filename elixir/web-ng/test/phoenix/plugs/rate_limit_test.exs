defmodule ServiceRadarWebNGWeb.Plugs.RateLimitTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadarWebNGWeb.Plugs.RateLimit

  @endpoint ServiceRadarWebNGWeb.Endpoint

  setup do
    # Clear the limiter table between tests so they don't leak state.
    :ets.delete_all_objects(RateLimiter.__table__())
    :ok
  end

  describe "happy path" do
    test "passes a request under the limit and adds ratelimit headers" do
      opts = RateLimit.init(bucket: :plug_test_allow, limit: 5, window_seconds: 60)
      conn = build_conn(:remote_ip, {203, 0, 113, 1})

      conn = RateLimit.call(conn, opts)

      refute conn.halted
      assert get_resp_header(conn, "x-ratelimit-limit") == ["5"]
      assert get_resp_header(conn, "x-ratelimit-remaining") == ["4"]
      assert [reset] = get_resp_header(conn, "x-ratelimit-reset")
      assert {parsed_reset, ""} = Integer.parse(reset)
      assert parsed_reset >= System.system_time(:second)
    end
  end

  describe "denial" do
    test "halts with 429 and retry-after once the bucket is exhausted" do
      opts = RateLimit.init(bucket: :plug_test_deny, limit: 2, window_seconds: 60)

      Enum.each(1..2, fn _ ->
        conn = build_conn(:remote_ip, {198, 51, 100, 1})
        refute RateLimit.call(conn, opts).halted
      end)

      denied = RateLimit.call(build_conn(:remote_ip, {198, 51, 100, 1}), opts)

      assert denied.halted
      assert denied.status == 429
      assert [retry_after] = get_resp_header(denied, "retry-after")
      assert {parsed, ""} = Integer.parse(retry_after)
      assert parsed >= 1
      assert get_resp_header(denied, "x-ratelimit-remaining") == ["0"]
      assert get_resp_header(denied, "x-ratelimit-limit") == ["2"]
      assert denied.resp_body =~ ~s("error":"rate_limited")
      assert denied.resp_body =~ ~s("retry_after":#{parsed})
    end

    test "different IPs do not interfere" do
      opts = RateLimit.init(bucket: :plug_test_per_ip, limit: 1, window_seconds: 60)

      conn1 = RateLimit.call(build_conn(:remote_ip, {192, 0, 2, 1}), opts)
      refute conn1.halted

      conn2 = RateLimit.call(build_conn(:remote_ip, {192, 0, 2, 2}), opts)
      refute conn2.halted

      same_again = RateLimit.call(build_conn(:remote_ip, {192, 0, 2, 1}), opts)
      assert same_again.halted
    end
  end

  describe "subject key derivation" do
    test "honors x-forwarded-for for the client IP" do
      opts = RateLimit.init(bucket: :plug_test_xff, limit: 1, window_seconds: 60)

      first =
        build_conn(:remote_ip, {10, 0, 0, 1})
        |> put_req_header("x-forwarded-for", "203.0.113.10, 10.0.0.1")
        |> RateLimit.call(opts)

      refute first.halted

      # A request from the SAME upstream IP (`x-forwarded-for`) should now
      # be denied even though the remote_ip differs.
      second =
        build_conn(:remote_ip, {10, 0, 0, 99})
        |> put_req_header("x-forwarded-for", "203.0.113.10, 10.0.0.99")
        |> RateLimit.call(opts)

      assert second.halted
    end

    test "ip_and_actor keys on (ip, actor_id) so password spraying does not collapse" do
      opts =
        RateLimit.init(
          bucket: :plug_test_spray,
          subject: :ip_and_actor,
          limit: 1,
          window_seconds: 60
        )

      alice =
        build_conn(:remote_ip, {198, 51, 100, 5})
        |> assign(:current_user, %{id: "alice"})

      bob =
        build_conn(:remote_ip, {198, 51, 100, 5})
        |> assign(:current_user, %{id: "bob"})

      refute RateLimit.call(alice, opts).halted
      # Same IP, different actor: independent bucket key.
      refute RateLimit.call(bob, opts).halted
      # Same IP, same actor: denied.
      assert RateLimit.call(alice, opts).halted
    end
  end

  describe "config-driven buckets" do
    test "uses bucket config when no explicit opts are supplied" do
      # auth_local is configured as 5/60s in core config.
      opts = RateLimit.init(bucket: :auth_local)

      Enum.each(1..5, fn _ ->
        conn = build_conn(:remote_ip, {172, 16, 0, 1})
        refute RateLimit.call(conn, opts).halted
      end)

      denied = RateLimit.call(build_conn(:remote_ip, {172, 16, 0, 1}), opts)
      assert denied.halted
      assert get_resp_header(denied, "x-ratelimit-limit") == ["5"]
    end
  end

  ## Helpers

  defp build_conn(:remote_ip, remote_ip) do
    %{Plug.Test.conn(:post, "/test") | remote_ip: remote_ip}
  end
end
