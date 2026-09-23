defmodule ServiceRadar.Observability.MtrAutomationDispatcherRegistryAbsentTest do
  # Not async: the assertion depends on no test in this BEAM having started the
  # process registry, which web-ng never joins.
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.MtrAutomationDispatcher
  alias ServiceRadar.ProcessRegistry

  @moduletag :db_free

  test "policy dispatch on a node without the process registry returns an error instead of raising" do
    refute ProcessRegistry.registry_present?()

    target_ctx = %{
      target: "192.0.2.10",
      target_ip: "192.0.2.10",
      partition_id: "default",
      target_key: "device:sr:00000000-0000-0000-0000-000000000001"
    }

    policy = %{target_selector: %{}, baseline_canary_vantages: 0}

    assert {:error, :no_candidates} =
             MtrAutomationDispatcher.dispatch_for_mode(target_ctx, policy, :baseline)
  end
end
