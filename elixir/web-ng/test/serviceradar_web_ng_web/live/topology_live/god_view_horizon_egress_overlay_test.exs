defmodule ServiceRadarWebNGWeb.TopologyLive.GodViewHorizonEgressOverlayTest do
  use ExUnit.Case, async: false

  alias Phoenix.LiveView.Socket
  alias ServiceRadarWebNGWeb.TopologyLive.GodViewControlState
  alias ServiceRadarWebNGWeb.TopologyLive.GodViewHorizonEgressOverlay

  @moduletag :db_free

  defp base_socket(assigns \\ %{}) do
    defaults = %{
      __changed__: %{},
      flash: %{},
      horizon_egress_cache: nil,
      mtr_paths_cache: nil,
      topology_layers: %{
        backbone: true,
        inferred: false,
        endpoints: false,
        mtr_paths: true,
        horizon_egress: false
      }
    }

    %Socket{assigns: Map.merge(defaults, assigns)}
  end

  defp pop_push_events(socket) do
    get_in(socket.private, [:live_temp, :push_events]) || []
  end

  test "normalizes string-keyed egress topology payload and preserves all Horizon fields" do
    sample_response = %{
      "max_hops" => 4,
      "truncated" => false,
      "egress_devices" => [
        %{
          "id" => "sr:edge-rtr-01",
          "kind" => "Device",
          "label" => "edge-rtr-01",
          "ip" => "192.0.2.1",
          "if_name" => "et-0/0/0",
          "if_index" => 12,
          "egress_source" => "manual",
          "port_speed_mbps" => 10_000
        }
      ],
      "external_nodes" => [
        %{
          "id" => "asn:64512",
          "kind" => "ASN",
          "label" => "Example Upstream",
          "asn" => 64_512,
          "region" => "us-east",
          "ip" => "198.51.100.1",
          "rpki_state" => "invalid",
          "rtbh_active" => true,
          "outage_state" => "outage",
          "port_speed_mbps" => 100_000,
          "metro" => "Ashburn",
          "iata" => "IAD",
          "country_code" => "US",
          "irr_status" => "valid"
        }
      ],
      "edges" => [
        %{
          "src_id" => "sr:edge-rtr-01",
          "dst_id" => "asn:64512",
          "kind" => "EGRESSES_TO",
          "border_asn" => 64_512,
          "as_boundary_confidence" => 0.95,
          "avg_rtt_us" => 14_200,
          "loss_pct" => 1.5,
          "port_speed_mbps" => 10_000,
          "if_name" => "et-0/0/0",
          "if_index" => 12,
          "egress_source" => "manual",
          "last_seen" => "2026-11-27T12:00:00Z"
        }
      ]
    }

    socket =
      GodViewHorizonEgressOverlay.push_egress_data(base_socket(),
        now_ms: 1_000,
        egress_topology_fun: fn opts ->
          assert opts[:max_hops] == 4
          assert opts[:limit] == 200
          {:ok, sample_response}
        end
      )

    assert [["god_view:horizon_egress_data", payload]] = pop_push_events(socket)
    assert payload.max_hops == 4
    assert payload.truncated == false
    assert [device] = payload.egress_devices
    assert device.id == "sr:edge-rtr-01"
    assert device.egress_source == "manual"
    assert device.port_speed_mbps == 10_000
    assert device.if_name == "et-0/0/0"
    assert device.if_index == 12

    assert [ext_node] = payload.external_nodes
    assert ext_node.id == "asn:64512"
    assert ext_node.asn == 64_512
    assert ext_node.rpki_state == "invalid"
    assert ext_node.rtbh_active == true
    assert ext_node.outage_state == "outage"
    assert ext_node.port_speed_mbps == 100_000
    assert ext_node.metro == "Ashburn"
    assert ext_node.iata == "IAD"
    assert ext_node.country_code == "US"
    assert ext_node.irr_status == "valid"

    assert [edge] = payload.edges
    assert edge.src_id == "sr:edge-rtr-01"
    assert edge.dst_id == "asn:64512"
    assert edge.avg_rtt_us == 14_200
    assert edge.loss_pct == 1.5
    assert edge.port_speed_mbps == 10_000
    assert edge.egress_source == "manual"
    assert edge.last_seen == "2026-11-27T12:00:00Z"

    # Must be JSON-encodable without raising
    assert is_binary(Jason.encode!(payload))
  end

  test "caches normalized payload for 10_000ms and refreshes after TTL expires" do
    calls = :counters.new(1, [])

    loader = fn _opts ->
      count = :counters.get(calls, 1) + 1
      :counters.put(calls, 1, count)

      {:ok,
       %{
         "max_hops" => count,
         "truncated" => false,
         "egress_devices" => [],
         "external_nodes" => [],
         "edges" => []
       }}
    end

    %Socket{} =
      socket1 =
      GodViewHorizonEgressOverlay.push_egress_data(base_socket(),
        now_ms: 10_000,
        egress_topology_fun: loader
      )

    assert [["god_view:horizon_egress_data", %{max_hops: 1}]] = pop_push_events(socket1)
    assert :counters.get(calls, 1) == 1

    # Within 10s TTL -> uses cache
    %Socket{} =
      socket2 =
      GodViewHorizonEgressOverlay.push_egress_data(
        %{socket1 | private: %{live_temp: %{}}},
        now_ms: 19_999,
        egress_topology_fun: loader
      )

    assert [["god_view:horizon_egress_data", %{max_hops: 1}]] = pop_push_events(socket2)
    assert :counters.get(calls, 1) == 1

    # At 10s TTL boundary -> reloads
    socket3 =
      GodViewHorizonEgressOverlay.push_egress_data(
        %{socket2 | private: %{live_temp: %{}}},
        now_ms: 20_000,
        egress_topology_fun: loader
      )

    assert [["god_view:horizon_egress_data", %{max_hops: 2}]] = pop_push_events(socket3)
    assert :counters.get(calls, 1) == 2
  end

  test "handles :graph_store_unavailable gracefully with empty payload and no error flash" do
    socket =
      GodViewHorizonEgressOverlay.push_egress_data(base_socket(),
        now_ms: 1_000,
        egress_topology_fun: fn _opts -> {:error, :graph_store_unavailable} end
      )

    assert socket.assigns.flash == %{}

    assert [["god_view:horizon_egress_data", payload]] = pop_push_events(socket)
    assert payload == GodViewHorizonEgressOverlay.empty_payload()
  end

  test "flashes error and clears payload on unexpected graph read failure" do
    socket =
      GodViewHorizonEgressOverlay.push_egress_data(base_socket(),
        now_ms: 1_000,
        egress_topology_fun: fn _opts -> {:error, :timeout} end
      )

    assert socket.assigns.flash["error"] =~ "Internet Egress / Horizon topology is unavailable"
    assert is_nil(socket.assigns.horizon_egress_cache)
    assert [["god_view:horizon_egress_data", payload]] = pop_push_events(socket)
    assert payload == GodViewHorizonEgressOverlay.empty_payload()
  end

  test "toggle_topology_layer toggles horizon_egress and pushes or clears egress data" do
    previous_fun = Application.get_env(:serviceradar_web_ng, :horizon_egress_topology_fun)

    Application.put_env(:serviceradar_web_ng, :horizon_egress_topology_fun, fn _opts ->
      {:ok,
       %{
         "max_hops" => 2,
         "truncated" => false,
         "egress_devices" => [%{"id" => "sr:gw-1", "egress_source" => "automagic"}],
         "external_nodes" => [%{"id" => "asn:64513", "kind" => "ASN", "asn" => 64_513}],
         "edges" => [%{"src_id" => "sr:gw-1", "dst_id" => "asn:64513", "kind" => "EGRESSES_TO"}]
       }}
    end)

    on_exit(fn ->
      if is_nil(previous_fun),
        do: Application.delete_env(:serviceradar_web_ng, :horizon_egress_topology_fun),
        else: Application.put_env(:serviceradar_web_ng, :horizon_egress_topology_fun, previous_fun)
    end)

    %Socket{} =
      socket_on = GodViewControlState.toggle_topology_layer(base_socket(), "horizon_egress")

    assert socket_on.assigns.topology_layers.horizon_egress == true

    events_on = pop_push_events(socket_on)

    assert Enum.any?(events_on, fn
             ["god_view:set_topology_layers", %{layers: %{"horizon_egress" => true}}] -> true
             _ -> false
           end)

    assert Enum.any?(events_on, fn
             ["god_view:horizon_egress_data", data] -> length(data.egress_devices) == 1
             _ -> false
           end)

    socket_off =
      GodViewControlState.toggle_topology_layer(
        %{socket_on | private: %{live_temp: %{}}},
        "horizon_egress"
      )

    assert socket_off.assigns.topology_layers.horizon_egress == false

    events_off = pop_push_events(socket_off)

    assert Enum.any?(events_off, fn
             ["god_view:set_topology_layers", %{layers: %{"horizon_egress" => false}}] -> true
             _ -> false
           end)

    assert ["god_view:horizon_egress_data", GodViewHorizonEgressOverlay.empty_payload()] in events_off
  end
end
