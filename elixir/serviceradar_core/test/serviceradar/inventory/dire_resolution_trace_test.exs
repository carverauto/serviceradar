defmodule ServiceRadar.Inventory.DireResolutionTraceTest do
  @moduledoc """
  Trace validation for `formal/dire/DireResolution.tla`.

  Each test builds a synthetic physical world, drives the real ingestion paths step by step
  through `ServiceRadar.DireTrace`, and requires the recorded trace to equal the committed
  `formal/dire/traces/Trace_<name>.{tla,cfg}`. `//formal/dire` model-checks those files against
  the model with the defect switches that match today's code. When the code changes behavior,
  the comparison here fails; regenerate with DIRE_TRACE_WRITE=1 on a scratch database and let
  the model check decide (formal/dire/README.md).
  """

  # Serial: the recorder attaches a global telemetry handler for identity decisions.
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.DireTrace
  alias ServiceRadar.TestSupport

  @moduletag :integration

  @observers ["Armis", "Discovery", "Arp", "Sweep"]

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:dire_resolution_trace_test)}
  end

  defp two_devices(overrides) do
    Map.merge(
      %{
        phys: ["h1", "h2"],
        ifaces: %{"x1" => %{phys: "h1", mac: "m1"}, "x2" => %{phys: "h2", mac: "m2"}},
        src_of: %{},
        armis_macs: true,
        src_ids: [],
        hw_ids: ["m1", "m2"],
        laa_ids: [],
        ips: ["p1", "p2"],
        observers: @observers
      },
      overrides
    )
  end

  # #4609 and #4639 (fixed): a discovered device leaves an address; an Armis device leases it.
  # Steps: A (m1) is seen at p1 three times (alias confirmed); A releases p1; Armis device B
  # (a2, m2) leases p1 and is synced. Expected: no merge; A's alias on p1 goes stale; B takes
  # p1 and A, still live, releases it, and the address conflict is recorded.
  test "armis_dhcp", %{actor: actor} do
    world = two_devices(%{src_of: %{"h2" => "a2"}, src_ids: ["a2"]})

    "armis_dhcp"
    |> DireTrace.start(world, actor)
    |> DireTrace.lease("x1", "p1")
    |> DireTrace.arp("h1", "x1")
    |> DireTrace.arp("h1", "x1")
    |> DireTrace.arp("h1", "x1")
    |> DireTrace.lease("x1", "NoIp")
    |> DireTrace.lease("x2", "p1")
    |> DireTrace.armis("h2", "x2")
    |> DireTrace.assert_golden!(tamper: true)
  end

  # #4610: an Armis device reported without MACs leaves an address; a discovered device leases
  # it. Steps: Armis A (a1) at p2 three times (alias confirmed); A moves to p1 and is synced
  # there; B (m2) is discovered at p3, then DHCP moves B to p2 and the mapper polls it. The
  # mapper resolves B by its MAC (#4638), so the alias of p2 reaches AliasGuard.
  test "alias_unknown_mac", %{actor: actor} do
    world =
      two_devices(%{
        src_of: %{"h1" => "a1"},
        src_ids: ["a1"],
        armis_macs: false,
        ips: ["p1", "p2", "p3"]
      })

    "alias_unknown_mac"
    |> DireTrace.start(world, actor)
    |> DireTrace.lease("x1", "p2")
    |> DireTrace.armis("h1", "x1")
    |> DireTrace.armis("h1", "x1")
    |> DireTrace.armis("h1", "x1")
    |> DireTrace.lease("x1", "p1")
    |> DireTrace.armis("h1", "x1")
    |> DireTrace.lease("x2", "p3")
    |> DireTrace.discovery("h2", "x2")
    |> DireTrace.lease("x2", "p2")
    |> DireTrace.discovery("h2", "x2")
    |> DireTrace.assert_golden!()
  end

  # #4610 (fixed) on its real path: agent check-in resolves through the Resolver, so AliasGuard
  # runs. Expected: no merge; A's alias on p2 is invalidated and A stays its own device.
  # Steps: Armis A (a1, no MAC reported) at p2 three times (alias confirmed); A moves to p1 and
  # is synced there; agent B (g2, m2) checks in at p3, DHCP moves B to p2, and B checks in again.
  test "agent_alias_unknown_mac", %{actor: actor} do
    world =
      two_devices(%{
        src_of: %{"h1" => "a1"},
        src_ids: ["a1"],
        agent_of: %{"h2" => "g2"},
        agent_ids: ["g2"],
        armis_macs: false,
        ips: ["p1", "p2", "p3"],
        observers: ["Armis", "Agent"]
      })

    "agent_alias_unknown_mac"
    |> DireTrace.start(world, actor)
    |> DireTrace.lease("x1", "p2")
    |> DireTrace.armis("h1", "x1")
    |> DireTrace.armis("h1", "x1")
    |> DireTrace.armis("h1", "x1")
    |> DireTrace.lease("x1", "p1")
    |> DireTrace.armis("h1", "x1")
    |> DireTrace.lease("x2", "p3")
    |> DireTrace.agent("h2", "x2")
    |> DireTrace.lease("x2", "p2")
    |> DireTrace.agent("h2", "x2")
    |> DireTrace.assert_golden!()
  end

  # #4611 (fixed): two Armis devices report the same MAC (cloned VMs, a swapped NIC).
  # Steps: A (a1, m1) is synced at p1; B (a2, m1) is synced at p2, twice. Expected: B gets its
  # own record, since its Armis id decides; m1 stays with A; each sync of B records the override.
  test "src_attach_shared_mac", %{actor: actor} do
    world =
      two_devices(%{
        ifaces: %{"x1" => %{phys: "h1", mac: "m1"}, "x2" => %{phys: "h2", mac: "m1"}},
        src_of: %{"h1" => "a1", "h2" => "a2"},
        src_ids: ["a1", "a2"],
        hw_ids: ["m1"],
        observers: ["Armis"]
      })

    "src_attach_shared_mac"
    |> DireTrace.start(world, actor)
    |> DireTrace.lease("x1", "p1")
    |> DireTrace.lease("x2", "p2")
    |> DireTrace.armis("h1", "x1")
    |> DireTrace.armis("h2", "x2")
    |> DireTrace.armis("h2", "x2")
    |> DireTrace.assert_golden!()
  end

  # #4612 (fixed): a router's interfaces are sighted one MAC at a time, then the mapper polls it.
  # The poll's MACs name both per-MAC records (#4638), and globally-unique MAC evidence merges
  # them into one record owning both MACs.
  test "router_mac_only", %{actor: actor} do
    world = %{
      phys: ["h1"],
      ifaces: %{"x1" => %{phys: "h1", mac: "m1"}, "x2" => %{phys: "h1", mac: "m2"}},
      src_of: %{},
      armis_macs: false,
      src_ids: [],
      hw_ids: ["m1", "m2"],
      laa_ids: [],
      ips: ["p1", "p2"],
      observers: @observers
    }

    "router_mac_only"
    |> DireTrace.start(world, actor)
    |> DireTrace.lease("x1", "p1")
    |> DireTrace.lease("x2", "p2")
    |> DireTrace.arp("h1", "x1")
    |> DireTrace.arp("h1", "x2")
    |> DireTrace.discovery("h1", "x1")
    |> DireTrace.assert_golden!()
  end

  # #4612 on the agent check-in path: a router's interfaces are sighted one MAC at a time, then
  # the agent on it checks in reporting both MACs. The records converge into one.
  test "agent_mac_split", %{actor: actor} do
    world = %{
      phys: ["h1"],
      ifaces: %{"x1" => %{phys: "h1", mac: "m1"}, "x2" => %{phys: "h1", mac: "m2"}},
      src_of: %{},
      agent_of: %{"h1" => "g1"},
      agent_ids: ["g1"],
      armis_macs: false,
      src_ids: [],
      hw_ids: ["m1", "m2"],
      laa_ids: [],
      ips: ["p1", "p2"],
      observers: ["Agent", "Arp"]
    }

    "agent_mac_split"
    |> DireTrace.start(world, actor)
    |> DireTrace.lease("x1", "p1")
    |> DireTrace.lease("x2", "p2")
    |> DireTrace.arp("h1", "x1")
    |> DireTrace.arp("h1", "x2")
    |> DireTrace.agent("h1", "x1")
    |> DireTrace.assert_golden!()
  end

  # #4638 (fixed): the mapper resolves a polled device by its interface MACs, not by the address
  # it was polled at. After DHCP moves an address from A to B, polling B there gives B its own
  # record, and A's record claims none of B's MACs.
  test "mapper_stale_address", %{actor: actor} do
    world = two_devices(%{})

    "mapper_stale_address"
    |> DireTrace.start(world, actor)
    |> DireTrace.lease("x1", "p1")
    |> DireTrace.discovery("h1", "x1")
    |> DireTrace.lease("x1", "p2")
    |> DireTrace.lease("x2", "p1")
    |> DireTrace.discovery("h2", "x2")
    |> DireTrace.assert_golden!()
  end
end
