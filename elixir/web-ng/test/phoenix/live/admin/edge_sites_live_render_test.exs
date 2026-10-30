defmodule ServiceRadarWebNGWeb.Admin.EdgeSitesLiveRenderTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadar.Edge.EdgeSite
  alias ServiceRadar.Edge.NatsLeafServer
  alias ServiceRadarWebNGWeb.Admin.EdgeSitesLive.Index
  alias ServiceRadarWebNGWeb.Admin.EdgeSitesLive.Show

  @moduletag :db_free

  setup_all do
    case ServiceRadarWebNGWeb.Endpoint.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  test "site rows render their optional single leaf server" do
    for {leaf, label} <- [
          {nil, "-"},
          {%NatsLeafServer{status: :pending}, "Provisioning"},
          {%NatsLeafServer{status: :provisioned}, "Ready"},
          {%NatsLeafServer{status: :connected}, "Connected"},
          {%NatsLeafServer{status: :disconnected}, "Disconnected"}
        ] do
      site = %EdgeSite{
        id: "00000000-0000-4000-8000-000000000021",
        name: "Example edge site",
        slug: "example-edge",
        status: :pending,
        inserted_at: ~U[2026-01-01 00:00:00Z],
        nats_leaf_server: leaf
      }

      html =
        render_component(&Index.render/1,
          flash: %{},
          current_scope: %{
            user: %{email: "operator@example.com", role: :admin, timezone: "Etc/UTC"}
          },
          settings_active_view: nil,
          settings_active_category: nil,
          settings_breadcrumbs: [],
          settings_nav_tree: %{categories: [], groups: []},
          settings_palette: [],
          settings_stats: [],
          sites: [site],
          filter_status: nil,
          show_create_modal: false
        )

      assert html =~ "Example edge site"

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("tbody tr td:nth-child(3)")
             |> LazyHTML.text()
             |> String.trim() == label
    end
  end

  test "site details render site and leaf timestamps in the user timezone" do
    for timezone <- ["Pacific/Auckland", nil], leaf? <- [false, true] do
      leaf =
        if leaf? do
          %NatsLeafServer{
            status: :connected,
            upstream_url: "tls://hub.example.com:7422",
            provisioned_at: ~U[2026-01-02 03:04:05Z],
            connected_at: ~U[2026-01-02 03:05:06Z]
          }
        end

      site = %EdgeSite{
        id: "00000000-0000-4000-8000-000000000022",
        name: "Example detail site",
        slug: "example-detail",
        status: :active,
        inserted_at: ~U[2026-01-01 00:00:00Z],
        nats_leaf_server: leaf
      }

      document =
        (&Show.render/1)
        |> render_component(
          flash: %{},
          current_scope: %{
            user: %{email: "operator@example.com", role: :admin, timezone: timezone}
          },
          settings_active_view: nil,
          settings_active_category: nil,
          settings_breadcrumbs: [],
          settings_nav_tree: %{categories: [], groups: []},
          settings_palette: [],
          settings_stats: [],
          site: site,
          leaf_server: leaf,
          collectors: [],
          collectors_enabled: true
        )
        |> LazyHTML.from_fragment()

      timestamps =
        if leaf? do
          [
            {"inserted-at", "2026-01-01T00:00:00Z"},
            {"leaf-provisioned-at", "2026-01-02T03:04:05Z"},
            {"leaf-connected-at", "2026-01-02T03:05:06Z"}
          ]
        else
          [{"inserted-at", "2026-01-01T00:00:00Z"}]
        end

      for {suffix, iso} <- timestamps do
        time = LazyHTML.query(document, "#admin-edge-site-#{site.id}-#{suffix}")
        assert LazyHTML.attribute(time, "datetime") == [iso]
        assert LazyHTML.attribute(time, "data-user-time-zone") == [timezone || "Etc/UTC"]
      end
    end
  end
end
