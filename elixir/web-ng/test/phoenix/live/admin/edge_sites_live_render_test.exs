defmodule ServiceRadarWebNGWeb.Admin.EdgeSitesLiveRenderTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadar.Edge.EdgeSite
  alias ServiceRadar.Edge.NatsLeafServer
  alias ServiceRadarWebNGWeb.Admin.EdgeSitesLive.Index

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
          current_scope: %{user: %{email: "operator@example.com", role: :admin, timezone: "Etc/UTC"}},
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
end
