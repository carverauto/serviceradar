defmodule ServiceRadarWebNG.Plugins.EgressConnectivityCheckTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Plugins.EgressConnectivityCheck

  @moduletag :db_free

  describe "required_hosts/0" do
    test "names every host the first-party sync needs" do
      hosts = Enum.map(EgressConnectivityCheck.required_hosts(), & &1.host)

      assert "github.com" in hosts
      assert "api.github.com" in hosts
      assert "release-assets.githubusercontent.com" in hosts
      assert "objects.githubusercontent.com" in hosts
      assert "registry.carverauto.dev" in hosts
    end
  end

  describe "run/1" do
    test "reports blocked hosts with a mapped reason" do
      prober = fn
        "github.com" ->
          :ok

        "api.github.com" ->
          :ok

        "release-assets.githubusercontent.com" ->
          :ok

        "objects.githubusercontent.com" ->
          :ok

        "github-releases.githubusercontent.com" ->
          :ok

        "registry.carverauto.dev" ->
          {:error, {:could_not_establish_ssl_tunnel, {~c"HTTP/1.1", 407, ~c"Request rejected by proxy"}}}
      end

      result = EgressConnectivityCheck.run(prober: prober)

      assert result.blocked == 1

      blocked = Enum.find(result.results, &(&1.host == "registry.carverauto.dev"))
      refute blocked.reachable
      assert blocked.detail =~ "egress proxy rejected the connection to registry.carverauto.dev"

      reachable = Enum.find(result.results, &(&1.host == "github.com"))
      assert reachable.reachable
    end

    test "all hosts reachable reports zero blocked" do
      result = EgressConnectivityCheck.run(prober: fn _host -> :ok end)

      assert result.blocked == 0
      assert length(result.results) == length(EgressConnectivityCheck.required_hosts())
    end
  end
end
