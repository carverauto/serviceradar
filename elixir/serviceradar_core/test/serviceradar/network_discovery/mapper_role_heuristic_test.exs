defmodule ServiceRadar.NetworkDiscovery.MapperRoleHeuristicTest do
  @moduledoc """
  Pins the mapper device-role scoring rules.

  These rules are cliff-edged: every term is an all-or-nothing `add_score`, so
  the interesting behaviour is entirely at exact boundaries and a one-character
  edit to a literal silently reclassifies devices fleet-wide. The heuristic had
  no direct coverage at all until this file, which is how a two-count-wide dead
  zone between `switch_l2` and `router` survived in production.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor

  # A switch with strong L2 evidence: one management IP, many physical ports,
  # no wireless. Only stable_l3_alias_count varies in the trajectory tests.
  defp switch_metrics(alias_count, overrides \\ %{}) do
    Map.merge(
      %{
        device_ip_count: 1,
        stable_l3_alias_count: alias_count,
        bridge_like_count: 0,
        physical_like_count: 24,
        wireless_like_count: 0
      },
      overrides
    )
  end

  defp role(metrics), do: MapperResultsIngestor.role_for_metrics(metrics)

  describe "switch_l2 across the alias-count trajectory" do
    # The regression this file exists for. Before the 1..2 term, counts 1 and 2
    # scored 40 -- below the threshold, and with `host` capped at 45 there was no
    # alternative above it either -- so a switch that gained a single out-of-band
    # management address or a global IPv6 fell to "unknown" until the count
    # reached 3 and `router` took over.
    test "a switch keeps its role from zero through two aliases" do
      assert %{role: "switch_l2", confidence: 75} = role(switch_metrics(0))
      assert %{role: "switch_l2", confidence: 65} = role(switch_metrics(1))
      assert %{role: "switch_l2", confidence: 65} = role(switch_metrics(2))
    end

    test "three or more aliases is a router, not a switch" do
      assert %{role: "router", confidence: 85} = role(switch_metrics(3))
      assert %{role: "router", confidence: 85} = role(switch_metrics(9))
    end

    test "a zero-alias switch still scores higher than one with aliases" do
      # The two alias terms are disjoint by their literal bounds. If a future
      # edit lets both fire, this ordering inverts.
      %{confidence: clean} = role(switch_metrics(0))
      %{confidence: with_mgmt_ip} = role(switch_metrics(1))

      assert clean > with_mgmt_ip
    end
  end

  describe "the gated term does not reach beyond switches" do
    test "a wireless device is never promoted by it" do
      metrics = switch_metrics(1, %{wireless_like_count: 2, bridge_like_count: 1})

      refute role(metrics).role == "switch_l2"
    end

    test "a device with few physical interfaces is not promoted" do
      # The assertion is that it is not a SWITCH. It resolves to "host" rather
      # than "unknown" since host_role_score became reachable -- a 4-interface
      # single-homed device is a host, and saying so is strictly better than
      # declining to classify it. What must not happen is switch_l2.
      result = role(switch_metrics(1, %{physical_like_count: 4}))

      refute result.role == "switch_l2"
      assert result.role == "host"
    end

    test "a device seen under several device_ips is not promoted" do
      # Deliberate: multiple device_ips is the split-record shape, where the fix
      # is identity merging. A role that hides it would be worse than "unknown".
      assert role(switch_metrics(1, %{device_ip_count: 3})).role != "switch_l2"
    end
  end

  describe "other roles" do
    test "an access point outscores switch_l2 on wireless evidence" do
      metrics = %{
        device_ip_count: 3,
        stable_l3_alias_count: 1,
        bridge_like_count: 2,
        physical_like_count: 2,
        wireless_like_count: 3
      }

      assert %{role: "ap_bridge"} = role(metrics)
    end

    test "a router needs three or more stable aliases" do
      base = %{
        device_ip_count: 1,
        stable_l3_alias_count: 2,
        bridge_like_count: 0,
        physical_like_count: 2,
        wireless_like_count: 0
      }

      refute role(base).role == "router"
      assert %{role: "router"} = role(%{base | stable_l3_alias_count: 3})
    end

    # Documents a real defect rather than endorsing it: host_role_score's terms
    # total 20+15+10 = 45 against a threshold of 50, so no input can produce the
    # role. Harmless today only because nothing distinguishes "host" from
    # "unknown" downstream. If the ceiling is ever raised, this test should fail
    # and be replaced with real host assertions.
    test "a genuine host resolves to host, not unknown and not switch_l2" do
      # Previously unreachable: the terms totalled 20+15+10 = 45 against a
      # threshold of 50, so this device scored "unknown" -- or switch_l2@55 once
      # alias==0, because that term did not require any L2 evidence.
      ideal_host = %{
        device_ip_count: 1,
        stable_l3_alias_count: 1,
        bridge_like_count: 0,
        physical_like_count: 1,
        wireless_like_count: 0
      }

      assert %{role: "host", confidence: 65} = role(ideal_host)
    end

    test "switch_l2 requires L2 evidence, not merely the absence of aliases" do
      # The observed defect: demo classified a 2-interface MikroTik -- whose own
      # SNMP type is "Router" -- as switch_l2@55, on alias==0 plus a single
      # device_ip and nothing switch-like at all.
      mikrotik = %{
        device_ip_count: 1,
        stable_l3_alias_count: 0,
        bridge_like_count: 0,
        physical_like_count: 1,
        wireless_like_count: 0
      }

      refute role(mikrotik).role == "switch_l2"
      assert %{role: "host"} = role(mikrotik)
    end

    test "a port-dense device is still a switch" do
      # The counterpart guard: narrowing switch_l2 must not cost a real switch
      # its role.
      assert %{role: "switch_l2", confidence: 75} = role(switch_metrics(0))
    end
  end

  describe "the live case this fixes" do
    test "switchcff8f2's shape resolves to switch_l2 instead of unknown" do
      # Observed on farm01 and demo: a switch with one out-of-band IPv4
      # management address on an `oob` interface, 217 physical interfaces, seen
      # under a single device_ip. It sat at unknown@40 on both clusters.
      observed = %{
        device_ip_count: 1,
        stable_l3_alias_count: 1,
        bridge_like_count: 0,
        physical_like_count: 217,
        wireless_like_count: 0
      }

      assert %{role: "switch_l2", confidence: 65} = role(observed)
    end
  end
end
