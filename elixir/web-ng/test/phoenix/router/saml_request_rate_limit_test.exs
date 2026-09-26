defmodule ServiceRadarWebNGWeb.Router.SAMLRequestRateLimitTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias ServiceRadar.Security.RateLimiter
  alias ServiceRadarWebNGWeb.Plugs.RateLimit

  @moduletag :db_free

  # Starting a SAML login persists a pending AuthnRequest row, so an
  # unauthenticated client must not be able to create them without bound. This
  # drives the real limiter with the options the `:rate_limit_auth_saml_request`
  # pipeline passes, against the production bucket definition.
  @start_opts [
    bucket: :auth_saml_request,
    subject: :ip,
    response_mode: :auto,
    html_redirect_to: "/users/log-in"
  ]

  setup_all do
    case Process.whereis(RateLimiter) do
      nil -> start_supervised!(RateLimiter)
      _pid -> :ok
    end

    :ok
  end

  setup do
    :ets.delete_all_objects(RateLimiter.__table__())
    :ok
  end

  test "one client is turned away from starting logins once its bucket is spent" do
    opts = RateLimit.init(@start_opts)
    {limit, _window} = RateLimiter.resolve_bucket(:auth_saml_request, [])

    for _ <- 1..limit do
      refute RateLimit.call(browser_conn({203, 0, 113, 7}), opts).halted
    end

    denied = RateLimit.call(browser_conn({203, 0, 113, 7}), opts)

    assert denied.halted
    assert denied.status == 303
    assert get_resp_header(denied, "location") == ["/users/log-in"]
    assert [_retry_after] = get_resp_header(denied, "retry-after")
  end

  test "another client is unaffected" do
    opts = RateLimit.init(@start_opts)
    {limit, _window} = RateLimiter.resolve_bucket(:auth_saml_request, [])

    for _ <- 1..(limit + 1), do: RateLimit.call(browser_conn({203, 0, 113, 7}), opts)

    refute RateLimit.call(browser_conn({203, 0, 113, 8}), opts).halted
  end

  test "exhausting the start bucket leaves the assertion consumer's bucket alone" do
    start = RateLimit.init(@start_opts)
    consume = RateLimit.init(Keyword.put(@start_opts, :bucket, :auth_saml_callback))
    {limit, _window} = RateLimiter.resolve_bucket(:auth_saml_request, [])

    for _ <- 1..(limit + 1), do: RateLimit.call(browser_conn({203, 0, 113, 7}), start)

    refute RateLimit.call(browser_conn({203, 0, 113, 7}), consume).halted
  end

  defp browser_conn(remote_ip) do
    %{Plug.Test.conn(:get, "/auth/saml") | remote_ip: remote_ip}
    |> put_req_header("accept", "text/html")
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Phoenix.Controller.fetch_flash([])
  end
end
