defmodule ServiceRadarWebNGWeb.SRQL.PageTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.SRQL.Page

  test "shortcut_query translates a bare IPv4 address to a device IP query" do
    assert Page.shortcut_query("192.168.2.10") == ~s(in:devices ip:"192.168.2.10")
  end

  test "shortcut_query translates a bare hostname to a device hostname query" do
    assert Page.shortcut_query("pve04.local") == ~s(in:devices hostname:"pve04.local")
  end

  test "shortcut_query preserves explicit SRQL" do
    assert Page.shortcut_query("in:devices metadata.proxmox_candidate:true") ==
             "in:devices metadata.proxmox_candidate:true"
  end
end
