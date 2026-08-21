defmodule ServiceRadar.HTTP.EgressProxyTest do
  use ExUnit.Case, async: true

  alias Req.Request
  alias ServiceRadar.HTTP.EgressProxy

  describe "parse/1" do
    test "blank is unset" do
      assert EgressProxy.parse(nil) == nil
      assert EgressProxy.parse("") == nil
    end

    test "http URL with an explicit port" do
      assert EgressProxy.parse("http://smokescreen.egress.svc.cluster.local:4750") == %{
               scheme: :http,
               host: "smokescreen.egress.svc.cluster.local",
               port: 4750
             }
    end

    test "http URL without a port defaults to 80" do
      assert EgressProxy.parse("http://proxy.internal") == %{
               scheme: :http,
               host: "proxy.internal",
               port: 80
             }
    end

    test "HTTPS is rejected" do
      assert_raise ArgumentError, ~r/not HTTPS/, fn ->
        EgressProxy.parse("https://smokescreen.egress.svc:4750")
      end
    end

    test "garbage is rejected" do
      assert_raise ArgumentError, ~r/HTTP CONNECT proxy URL/, fn ->
        EgressProxy.parse("not-a-url")
      end
    end
  end

  describe "from_env/1" do
    test "reads SERVICERADAR_EGRESS_PROXY" do
      env = %{"SERVICERADAR_EGRESS_PROXY" => "http://smokescreen.egress:4750"}

      assert EgressProxy.from_env(env) == %{
               scheme: :http,
               host: "smokescreen.egress",
               port: 4750
             }
    end

    test "missing variable is unset" do
      assert EgressProxy.from_env(%{}) == nil
    end
  end

  describe "finch_pools/1" do
    test "unset proxy still installs CAStore when it is available" do
      pools = EgressProxy.finch_pools(nil)

      if Code.ensure_loaded?(CAStore) and function_exported?(CAStore, :file_path, 0) do
        assert %{default: [conn_opts: opts]} = pools
        assert opts[:transport_opts][:cacertfile] == CAStore.file_path()
        refute Keyword.has_key?(opts, :proxy)
      else
        assert pools == nil
      end
    end

    test "set proxy is a Mint CONNECT tuple" do
      pools =
        EgressProxy.finch_pools(%{
          scheme: :http,
          host: "smokescreen.egress.svc.cluster.local",
          port: 4750
        })

      assert %{default: [conn_opts: opts]} = pools

      assert opts[:proxy] ==
               {:http, "smokescreen.egress.svc.cluster.local", 4750, []}
    end
  end

  describe "req_opts/1" do
    test "uses the named Finch pool without connect_options" do
      opts = EgressProxy.req_opts(15_000)

      assert Keyword.get(opts, :finch) == [name: ServiceRadar.Finch]
      assert Keyword.get(opts, :receive_timeout) == 15_000
      assert Keyword.get(opts, :retry) == false
      refute Keyword.has_key?(opts, :connect_options)

      request = Req.new(opts ++ [url: "https://example.invalid/"])
      assert Request.get_option(request, :finch) == [name: ServiceRadar.Finch]
      refute Request.get_option(request, :connect_options)
    end

    test "Req raises when a named Finch is combined with connect_options" do
      request =
        Req.new(
          url: "https://example.invalid/",
          finch: [name: ServiceRadar.Finch],
          connect_options: [timeout: 1_000]
        )

      assert_raise ArgumentError, ~r/cannot set both :finch and :connect_options/, fn ->
        Request.run_request(request)
      end
    end
  end
end
