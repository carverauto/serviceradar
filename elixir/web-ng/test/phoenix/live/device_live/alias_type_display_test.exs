defmodule ServiceRadarWebNGWeb.DeviceLive.AliasTypeDisplayTest do
  @moduledoc """
  The IP Aliases panel shows identity and interface addresses together, and must
  label which is which.

  `:ip` is what DIRE merges devices on. `:interface_ip` is an address observed on
  the device's own interface and deliberately excluded from merging, because
  interface tables carry addresses several devices legitimately report (VRRP/HSRP
  virtual IPs, EVPN anycast gateways, Junos internals like 10.0.0.4). Rendering
  both without distinction would tell an operator that "this device has 10.0.0.4"
  is an identity claim when it is only an observation.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ServiceRadarWebNGWeb.DeviceLive.SweepComponents

  # Required for this to run at all. The web-ng suite excludes every test by
  # default and re-includes only `:db_free`, so a file without this tag is loaded
  # and then silently skipped -- the shard passes while covering nothing.
  @moduletag :db_free

  # The label/variant helpers are private; exercise them through the rendered
  # markup, which is also what actually has to be right.
  defp render_panel(aliases) do
    render_component(&SweepComponents.ip_aliases_section/1,
      aliases: aliases,
      error: nil,
      show_stale: false
    )
  end

  defp alias_row(value, type, state \\ :confirmed) do
    %{
      alias_value: value,
      alias_type: type,
      state: state,
      sighting_count: 3,
      last_seen_at: ~U[2026-08-23 12:00:00Z]
    }
  end

  test "an identity alias renders as Identity" do
    html = render_panel([alias_row("192.168.2.55", :ip)])

    assert html =~ "192.168.2.55"
    assert html =~ "Identity"
  end

  test "an interface address renders as Interface, not Identity" do
    html = render_panel([alias_row("192.168.1.143", :interface_ip)])

    assert html =~ "192.168.1.143"
    assert html =~ "Interface"
  end

  test "both types render together and stay distinguishable" do
    # The motivating case: switchcff8f2's primary is an identity alias, its
    # out-of-band management address is only an interface observation.
    html =
      render_panel([
        alias_row("192.168.2.55", :ip),
        alias_row("192.168.1.143", :interface_ip)
      ])

    assert html =~ "192.168.2.55"
    assert html =~ "192.168.1.143"
    assert html =~ "Identity"
    assert html =~ "Interface"
  end

  test "a shared vendor-internal address is never labelled Identity" do
    html = render_panel([alias_row("10.0.0.4", :interface_ip)])

    assert html =~ "Interface"
    refute html =~ ">Identity<"
  end
end
