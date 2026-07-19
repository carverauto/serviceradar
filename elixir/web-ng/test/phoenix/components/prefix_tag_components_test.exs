defmodule ServiceRadarWebNGWeb.Components.PrefixTagComponentsTest do
  @moduledoc """
  Unit coverage for prefix-tag chips on the flow listing and modal endpoints.
  """

  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Components.PrefixTagChips
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.View.FlowModal.Endpoints
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.View.FlowsTable

  @moduletag :unit
  @moduletag :db_free

  setup_all do
    case start_supervised(ServiceRadarWebNGWeb.Endpoint) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  test "shared PrefixTagChips.linked renders filter links" do
    html =
      render_component(&PrefixTagChips.linked/1, %{
        items: [
          %{tag: "netbox:tag:iot", path: "/observability?q=in%3Aflows+tag%3Anetbox%3Atag%3Aiot"},
          %{tag: "site:austin", path: "/observability?q=in%3Aflows+tag%3Asite%3Aaustin"}
        ]
      })

    assert html =~ "netbox:tag:iot"
    assert html =~ "site:austin"
    assert html =~ "Filter flows with tag netbox:tag:iot"
    assert html =~ "href="
  end

  test "shared PrefixTagChips.static renders badges without links" do
    html =
      render_component(&PrefixTagChips.static/1, %{
        tags: ["provider:cloudflare"]
      })

    assert html =~ "provider:cloudflare"
    assert html =~ "Prefix tag: provider:cloudflare"
    refute html =~ "href="
  end

  test "prefix_tag_chips is empty when there are no tags" do
    html =
      render_component(&PrefixTagChips.linked/1, %{
        items: []
      })

    refute html =~ "badge"
    refute html =~ "Filter flows with tag"
  end

  test "flows table renders src/dst chips from column fields" do
    html =
      render_component(&FlowsTable.render/1, %{
        flows: [
          %{
            "time" => "2026-02-27T21:00:00Z",
            "src_endpoint_ip" => "10.1.2.3",
            "dst_endpoint_ip" => "8.8.8.8",
            "src_endpoint_port" => 12_345,
            "dst_endpoint_port" => 443,
            "protocol_num" => 6,
            "protocol_name" => "tcp",
            "packets_total" => 10,
            "bytes_total" => 2048,
            "src_prefix_tags" => ["netbox:tag:corp", "role:wifi"],
            "dst_prefix_tags" => ["provider:cloudflare"]
          }
        ],
        rdns_map: %{},
        geo_iso2_map: %{},
        base_path: "/observability",
        query: "in:flows",
        limit: 50,
        nf_param: nil,
        unit_mode: "Bps"
      })

    assert html =~ "netbox:tag:corp"
    assert html =~ "role:wifi"
    assert html =~ "provider:cloudflare"
    assert html =~ "10.1.2.3"
    assert html =~ "8.8.8.8"
  end

  test "flows table renders chips from ocsf enrichment payload" do
    html =
      render_component(&FlowsTable.render/1, %{
        flows: [
          %{
            "time" => "2026-02-27T21:00:00Z",
            "src_endpoint_ip" => "192.0.2.10",
            "dst_endpoint_ip" => "198.51.100.20",
            "protocol_num" => 6,
            "packets_total" => 1,
            "bytes_total" => 64,
            "ocsf_payload" => %{
              "enrichment" => %{
                "src_prefix_tags" => ["ti:otx:malware"],
                "dst_prefix_tags" => ["dns-policy:rpz"]
              }
            }
          }
        ],
        rdns_map: %{},
        geo_iso2_map: %{},
        base_path: "/observability",
        query: "in:flows",
        limit: 50,
        nf_param: nil,
        unit_mode: "Bps"
      })

    assert html =~ "ti:otx:malware"
    assert html =~ "dns-policy:rpz"
  end

  test "flows table omits chips when tags are absent" do
    html =
      render_component(&FlowsTable.render/1, %{
        flows: [
          %{
            "time" => "2026-02-27T21:00:00Z",
            "src_endpoint_ip" => "10.0.0.1",
            "dst_endpoint_ip" => "10.0.0.2",
            "protocol_num" => 6,
            "packets_total" => 1,
            "bytes_total" => 64
          }
        ],
        rdns_map: %{},
        geo_iso2_map: %{},
        base_path: "/observability",
        query: "in:flows",
        limit: 50,
        nf_param: nil,
        unit_mode: "Bps"
      })

    refute html =~ "badge badge-outline badge-xs font-mono"
    refute html =~ "Filter flows with tag"
  end

  test "endpoint card shows prefix tags on source and destination" do
    flow = %{
      "src_endpoint_ip" => "10.1.2.3",
      "dst_endpoint_ip" => "8.8.8.8",
      "src_prefix_tags" => ["site:hq"],
      "dst_prefix_tags" => ["provider:google"],
      "ocsf_payload" => %{}
    }

    context = %{src_device_uid: nil, dst_device_uid: nil}

    src =
      render_component(&Endpoints.endpoint_card/1, %{
        flow: flow,
        context: context,
        rdns_map: %{},
        side: :src,
        geo: nil
      })

    dst =
      render_component(&Endpoints.endpoint_card/1, %{
        flow: flow,
        context: context,
        rdns_map: %{},
        side: :dst,
        geo: nil
      })

    assert src =~ "site:hq"
    assert src =~ "Prefix tag: site:hq"
    refute src =~ "provider:google"

    assert dst =~ "provider:google"
    assert dst =~ "Prefix tag: provider:google"
    refute dst =~ "site:hq"
  end

  test "endpoint card leaves untagged flows unchanged" do
    html =
      render_component(&Endpoints.endpoint_card/1, %{
        flow: %{
          "src_endpoint_ip" => "10.0.0.1",
          "ocsf_payload" => %{}
        },
        context: %{src_device_uid: nil, dst_device_uid: nil},
        rdns_map: %{},
        side: :src,
        geo: nil
      })

    assert html =~ "10.0.0.1"
    refute html =~ "Prefix tag:"
  end
end
