defmodule ServiceRadarWebNGWeb.SRQL.PageTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
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

  test "sync_from_params applies URL query to draft before data load" do
    socket = Page.init(%Socket{}, "logs", default_limit: 20)

    socket =
      Page.sync_from_params(
        socket,
        %{
          "q" => ~s(in:logs device_id:"sr:device-1" time:last_24h sort:timestamp:desc),
          "limit" => "50"
        },
        "https://example.test/observability?tab=logs",
        default_limit: 20,
        max_limit: 100
      )

    assert socket.assigns.srql.draft ==
             ~s(in:logs device_id:"sr:device-1" time:last_24h sort:timestamp:desc)

    assert socket.assigns.srql.query == socket.assigns.srql.draft
    assert socket.assigns.srql.loading
    assert socket.assigns.limit == 50
  end
end
