defmodule ServiceRadarWebNGWeb.NetflowLive.FlowSourceRenderingTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.View.FlowsTable

  @moduletag :db_free

  # Warehouse rows carry the exporter protocol as a `flow_source` column and have
  # no ocsf_payload; CNPG-era rows carry it inside ocsf_payload, the oldest only
  # as the collector's flow_type code. Every shape must label the same way.
  test "flow rows label the exporter protocol from every row shape" do
    rows = [
      flow("warehouse", %{"flow_source" => "IPFIX"}),
      flow("warehouse-unknown", %{"flow_source" => "Unknown"}),
      flow("cnpg", %{"ocsf_payload" => %{"flow_source" => "sFlow v5"}}),
      flow("cnpg-legacy", %{"ocsf_payload" => %{"unmapped" => %{"flow_type" => "NETFLOW_V9"}}})
    ]

    html =
      render_component(&FlowsTable.render/1, %{
        flows: rows,
        base_path: "/observability/flows",
        query: "in:flows time:last_1h",
        limit: 50
      })

    labels =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("tbody tr > td:nth-child(5)")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

    assert labels == ["IPFIX", "—", "sFlow v5", "NetFlow v9"]
  end

  defp flow(id, source_fields) do
    Map.merge(
      %{
        "id" => id,
        "time" => "2026-08-30T18:00:00Z",
        "src_endpoint_ip" => "192.0.2.10",
        "dst_endpoint_ip" => "198.51.100.20",
        "src_endpoint_port" => 12_345,
        "dst_endpoint_port" => 443,
        "protocol_num" => 6,
        "protocol_name" => "tcp",
        "packets_total" => 1,
        "bytes_total" => 64
      },
      source_fields
    )
  end
end
