defmodule ServiceRadar.GatewayRegistryRegistryAbsentTest do
  # Not async: the assertions depend on no test in this BEAM having started the
  # process registry, which web-ng never joins.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.GatewayRegistry
  alias ServiceRadar.ProcessRegistry

  @moduletag :db_free

  test "gateway reads without the process registry return defaults instead of raising" do
    refute ProcessRegistry.registry_present?()

    log =
      capture_log(fn ->
        assert GatewayRegistry.find_available_gateways() == []
        assert GatewayRegistry.find_gateways() == []
        assert GatewayRegistry.count() == 0
      end)

    assert log =~ "No registry member reachable for find_available_gateways/0"
  end
end
