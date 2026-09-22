defmodule ServiceRadar.HTTP.EgressProxyTest do
  # Not async: one test sets the :egress_proxy application env.
  use ExUnit.Case, async: false

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

  describe "finch_pools/0" do
    test "installs CAStore when it is available" do
      pools = EgressProxy.finch_pools()

      if Code.ensure_loaded?(CAStore) and function_exported?(CAStore, :file_path, 0) do
        assert %{default: [conn_opts: opts]} = pools
        assert opts[:transport_opts][:cacertfile] == CAStore.file_path()
        refute Keyword.has_key?(opts, :proxy)
      else
        assert pools == nil
      end
    end

    # Mint cannot tunnel through a goproxy-style CONNECT reply (see
    # ServiceRadar.HTTP.EgressClient), so a proxy on the shared pool fails every
    # request made on it -- and would also send in-cluster targets to a proxy
    # that denies them. External hosts go through EgressClient instead.
    test "a configured egress proxy is never installed on the shared pool" do
      previous = Application.fetch_env(:serviceradar_core, :egress_proxy)

      Application.put_env(:serviceradar_core, :egress_proxy, %{
        scheme: :http,
        host: "smokescreen.egress.svc.cluster.local",
        port: 4750
      })

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:serviceradar_core, :egress_proxy, value)
          :error -> Application.delete_env(:serviceradar_core, :egress_proxy)
        end
      end)

      conn_opts = get_in(EgressProxy.finch_pools() || %{}, [:default, :conn_opts]) || []

      refute Keyword.has_key?(conn_opts, :proxy)
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

  # The pool connects directly, so a request on it to a host outside the
  # deployment bypasses SERVICERADAR_EGRESS_PROXY and is refused wherever a
  # default-deny NetworkPolicy admits only the proxy. External fetches go through
  # ServiceRadar.HTTP.EgressClient. A module belongs on this list only if every
  # host it reaches through the pool is in-cluster or configured by the operator.
  @pool_users [
    # Starts the pool.
    "lib/serviceradar/application.ex",
    # Explains why it does not use the pool.
    "lib/serviceradar/http/egress_client.ex",
    # Defines the pool options.
    "lib/serviceradar/http/egress_proxy.ex",
    # req_opts/1, kept for operator-configured targets.
    "lib/serviceradar/observability/outbound_feed_policy.ex",
    # Operator-configured NetBox, usually on the LAN.
    "lib/serviceradar/prefix_tags/netbox_import_worker.ex"
  ]

  @pool_references ["ServiceRadar.Finch", "EgressProxy.req_opts", "OutboundFeedPolicy.req_opts"]

  describe "shared pool users" do
    test "only in-cluster and operator-configured clients use the shared pool" do
      root = Path.expand("../../..", __DIR__)

      users =
        root
        |> Path.join("lib/**/*.ex")
        |> Path.wildcard()
        |> Enum.filter(&String.contains?(File.read!(&1), @pool_references))
        |> Enum.map(&Path.relative_to(&1, root))

      # Proves the scan read the tree; an empty scan would pass vacuously.
      assert "lib/serviceradar/application.ex" in users
      assert Enum.sort(users -- @pool_users) == []
    end
  end
end
