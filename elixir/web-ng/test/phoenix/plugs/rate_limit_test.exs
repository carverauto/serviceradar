defmodule ServiceRadarWebNGWeb.Plugs.RateLimitTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadarWebNGWeb.Plugs.RateLimit

  @moduletag :db_free

  setup_all do
    case Process.whereis(RateLimiter) do
      nil -> start_supervised!(RateLimiter)
      _pid -> :ok
    end

    :ok
  end

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
        :remote_ip
        |> build_conn({10, 0, 0, 1})
        |> put_req_header("x-forwarded-for", "203.0.113.10, 10.0.0.1")
        |> RateLimit.call(opts)

      refute first.halted

      # A request from the SAME upstream IP (`x-forwarded-for`) should now
      # be denied even though the remote_ip differs.
      second =
        :remote_ip
        |> build_conn({10, 0, 0, 99})
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
        :remote_ip
        |> build_conn({198, 51, 100, 5})
        |> assign(:current_user, %{id: "alice"})

      bob =
        :remote_ip
        |> build_conn({198, 51, 100, 5})
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

    test "standalone web release retains the login limit without dependency config" do
      without_rate_limiter_config(fn ->
        assert {5, 60} = RateLimiter.resolve_bucket(:auth_local)
        assert_bucket_denies_sixth_request(:auth_local, {172, 16, 0, 11})
      end)
    end

    test "standalone web release retains the password-reset limit without dependency config" do
      without_rate_limiter_config(fn ->
        assert {5, 300} = RateLimiter.resolve_bucket(:auth_password_reset)
        assert_bucket_denies_sixth_request(:auth_password_reset, {172, 16, 0, 12})
      end)
    end
  end

  describe "response_mode: :html" do
    test "halts with a 303 redirect when over the limit" do
      opts =
        RateLimit.init(
          bucket: :plug_test_html,
          limit: 1,
          window_seconds: 60,
          response_mode: :html,
          html_redirect_to: "/auth/local"
        )

      _ = RateLimit.call(build_conn(:remote_ip, {198, 51, 100, 50}), opts)
      denied = RateLimit.call(build_conn(:remote_ip, {198, 51, 100, 50}), opts)

      assert denied.halted
      assert denied.status == 303
      assert get_resp_header(denied, "location") == ["/auth/local"]
      assert get_resp_header(denied, "retry-after") != []
    end

    test "renders {retry_after} in the configured flash template" do
      opts =
        RateLimit.init(
          bucket: :plug_test_html_flash,
          limit: 1,
          window_seconds: 60,
          response_mode: :html,
          html_redirect_to: "/auth/local",
          html_flash_template: "Hold up — wait {retry_after}s."
        )

      _ = RateLimit.call(build_conn_with_flash({203, 0, 113, 90}), opts)
      denied = RateLimit.call(build_conn_with_flash({203, 0, 113, 90}), opts)

      assert denied.halted
      flash = Phoenix.Flash.get(denied.assigns.flash, :error)
      assert flash =~ ~r/Hold up — wait \d+s\./
    end

    test "redirect target may be a 0-arity function" do
      opts =
        RateLimit.init(
          bucket: :plug_test_html_fun,
          limit: 1,
          window_seconds: 60,
          response_mode: :html,
          html_redirect_to: fn -> "/auth/sign-in" end
        )

      _ = RateLimit.call(build_conn(:remote_ip, {10, 10, 10, 10}), opts)
      denied = RateLimit.call(build_conn(:remote_ip, {10, 10, 10, 10}), opts)

      assert denied.status == 303
      assert get_resp_header(denied, "location") == ["/auth/sign-in"]
    end
  end

  describe "response_mode: :auto" do
    test "JSON 429 when accept does not prefer html" do
      opts =
        RateLimit.init(bucket: :plug_test_auto_json, limit: 1, window_seconds: 60)

      _ = RateLimit.call(build_conn(:remote_ip, {192, 0, 2, 11}), opts)

      denied =
        :remote_ip
        |> build_conn({192, 0, 2, 11})
        |> put_req_header("accept", "application/json")
        |> RateLimit.call(opts)

      assert denied.status == 429
      assert denied.resp_body =~ "rate_limited"
    end

    test "HTML 303 when accept prefers text/html" do
      opts =
        RateLimit.init(
          bucket: :plug_test_auto_html,
          limit: 1,
          window_seconds: 60,
          html_redirect_to: "/users/log-in"
        )

      _ =
        :remote_ip
        |> build_conn({192, 0, 2, 22})
        |> put_req_header("accept", "text/html,application/xhtml+xml")
        |> RateLimit.call(opts)

      denied =
        :remote_ip
        |> build_conn({192, 0, 2, 22})
        |> put_req_header("accept", "text/html,application/xhtml+xml")
        |> RateLimit.call(opts)

      assert denied.status == 303
      assert get_resp_header(denied, "location") == ["/users/log-in"]
    end
  end

  describe "init/1 validation" do
    test "rejects unknown response_mode" do
      assert_raise ArgumentError, ~r/:response_mode must be/, fn ->
        RateLimit.init(bucket: :anything, response_mode: :wat)
      end
    end

    test "rejects a non-function json_body_builder" do
      assert_raise ArgumentError, ~r/:json_body_builder must be/, fn ->
        RateLimit.init(bucket: :anything, json_body_builder: "not a fn")
      end
    end
  end

  describe "json_body_builder" do
    test "supplied body is used verbatim on denial" do
      opts =
        RateLimit.init(
          bucket: :plug_test_builder,
          limit: 1,
          window_seconds: 60,
          response_mode: :json,
          json_body_builder: fn ra ->
            ~s({"code":429,"retry":#{ra},"err":"rl"})
          end
        )

      _ = RateLimit.call(build_conn(:remote_ip, {172, 16, 1, 1}), opts)
      denied = RateLimit.call(build_conn(:remote_ip, {172, 16, 1, 1}), opts)

      assert denied.status == 429
      assert denied.resp_body =~ ~r/^\{"code":429,"retry":\d+,"err":"rl"\}$/
    end

    test "unset builder keeps the default body" do
      opts =
        RateLimit.init(bucket: :plug_test_no_builder, limit: 1, window_seconds: 60)

      _ = RateLimit.call(build_conn(:remote_ip, {172, 16, 2, 1}), opts)
      denied = RateLimit.call(build_conn(:remote_ip, {172, 16, 2, 1}), opts)

      assert denied.resp_body =~ ~r/"error":"rate_limited"/
      assert denied.resp_body =~ ~r/"retry_after":\d+/
    end

    test "HTML mode ignores the builder" do
      opts =
        RateLimit.init(
          bucket: :plug_test_html_ignores_builder,
          limit: 1,
          window_seconds: 60,
          response_mode: :html,
          html_redirect_to: "/users/log-in",
          json_body_builder: fn _ -> ~s({"never":"used"}) end
        )

      _ = RateLimit.call(build_conn(:remote_ip, {172, 16, 3, 1}), opts)
      denied = RateLimit.call(build_conn(:remote_ip, {172, 16, 3, 1}), opts)

      assert denied.status == 303
      refute denied.resp_body =~ "never"
    end

    @tag :capture_log
    test "builder that raises falls back to the default body" do
      opts =
        RateLimit.init(
          bucket: :plug_test_builder_raises,
          limit: 1,
          window_seconds: 60,
          response_mode: :json,
          json_body_builder: fn _ -> raise "boom" end
        )

      _ = RateLimit.call(build_conn(:remote_ip, {172, 16, 4, 1}), opts)
      denied = RateLimit.call(build_conn(:remote_ip, {172, 16, 4, 1}), opts)

      assert denied.status == 429
      assert denied.resp_body =~ ~r/"error":"rate_limited"/
    end
  end

  ## Helpers

  defp without_rate_limiter_config(callback) do
    previous = Application.get_env(:serviceradar_core, RateLimiter)
    Application.delete_env(:serviceradar_core, RateLimiter)

    try do
      callback.()
    after
      if is_nil(previous),
        do: Application.delete_env(:serviceradar_core, RateLimiter),
        else: Application.put_env(:serviceradar_core, RateLimiter, previous)
    end
  end

  defp assert_bucket_denies_sixth_request(bucket, remote_ip) do
    opts = RateLimit.init(bucket: bucket)

    Enum.each(1..5, fn _ ->
      refute RateLimit.call(build_conn(:remote_ip, remote_ip), opts).halted
    end)

    denied = RateLimit.call(build_conn(:remote_ip, remote_ip), opts)
    assert denied.halted
    assert get_resp_header(denied, "x-ratelimit-limit") == ["5"]
  end

  defp build_conn(:remote_ip, remote_ip) do
    %{Plug.Test.conn(:post, "/test") | remote_ip: remote_ip}
  end

  # Sets up the `:flash` assign Phoenix's `fetch_flash` plug installs,
  # so `Phoenix.Controller.put_flash/3` works.
  defp build_conn_with_flash(remote_ip) do
    %{Plug.Test.conn(:post, "/test") | remote_ip: remote_ip}
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Phoenix.Controller.fetch_flash([])
  end
end
