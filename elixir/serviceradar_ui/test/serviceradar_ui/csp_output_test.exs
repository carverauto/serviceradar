defmodule ServiceRadarUI.CspOutputTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import ServiceRadarUI.Charts
  import ServiceRadarUI.Components
  import ServiceRadarUI.Maps
  import ServiceRadarUI.Shell

  test "every component and chart renders without inline style, script, or handlers" do
    html =
      render_component(&gallery/1, %{
        now: ~U[2026-11-27 12:00:00Z],
        values: [1, 3, 2, 5, 4, 6]
      })

    refute html =~ ~r/\sstyle\s*=/i
    refute html =~ ~r/<script\b/i
    refute html =~ ~r/\son[a-z]+\s*=/i
    refute html =~ "javascript:"

    for hook <- ~w(SrSparkline SrTimeseries SrWorldMap SrDialog) do
      assert html =~ ~s(phx-hook="#{hook}")
    end

    for class <-
          ~w(sr-ui-btn sr-ui-badge sr-ui-panel sr-ui-surface sr-ui-alert sr-ui-flash sr-ui-modal sr-ui-tabs sr-ui-dropdown sr-ui-table sr-ui-pagination sr-ui-spinner sr-ui-field sr-ui-skip-link sr-ui-topbar sr-ui-brand-lockup sr-ui-segmented sr-ui-footer sr-ui-theme-toggle sr-chart-sparkline sr-chart-area sr-chart-bar sr-chart-donut sr-chart-gauge sr-map) do
      assert html =~ class
    end

    assert html =~ ~s(data-sr-line)
    assert html =~ ~s(data-topology-url)
    assert html =~ "sr:set-theme"
  end

  test "shipped theme script, tokens and bundle stay CSP-safe" do
    priv = :code.priv_dir(:serviceradar_ui) |> to_string()
    theme = File.read!(Path.join(priv, "static/theme_init.js"))
    tokens = File.read!(Path.join(priv, "css/tokens.css"))
    bundle = File.read!(Path.join(priv, "static/serviceradar_ui.js"))

    assert theme =~ "sr:theme"
    assert theme =~ "data-sr-theme-key"
    refute theme =~ "<script"

    assert tokens =~ "light-dark("
    assert tokens =~ ~s([data-theme="light"])
    assert tokens =~ ~s([data-theme="dark"])
    assert tokens =~ "prefers-color-scheme: dark"
    assert tokens =~ "#0b824d"
    assert tokens =~ "#3ecf87"

    assert File.exists?(Path.join(priv, "static/serviceradar_ui.js.map"))
    assert File.exists?(Path.join(priv, "static/world-110m.json"))
    assert File.exists?(Path.join(priv, "static/logo-animated.svg"))
    assert File.exists?(Path.join(priv, "static/favicon.ico"))
    assert byte_size(bundle) > 10_000
    assert bundle =~ "SrWorldMap"
    refute bundle =~ "Fiji"
    refute bundle =~ "openstreetmap"
    refute bundle =~ "mapbox"
  end

  test "update events are addressed by element id" do
    assert ServiceRadarUI.update_event("edge-map") == "sr:update:edge-map"
  end

  defp gallery(assigns) do
    points = for i <- 0..5, do: {DateTime.add(assigns.now, i * 3600, :second), i * 2.0}

    assigns =
      assign(assigns,
        form:
          to_form(
            %{"email" => "ada@example.com", "role" => "admin", "notes" => "hi", "on" => "true"},
            as: :user
          ),
        points: points,
        rows: [%{id: "edge-a", name: "edge-a", status: "up"}]
      )

    ~H"""
    <.skip_link />
    <.top_bar>
      <:brand>
        <.brand_lockup navigate="/" title="ServiceRadar" subtitle="Global Observability" />
      </:brand>
      <:nav><a href="/devices" aria-current="page">Devices</a></:nav>
      <:mobile_nav><a href="/devices" aria-current="page">Devices</a></:mobile_nav>
      <:actions><.theme_toggle /></:actions>
    </.top_bar>
    <main id="main" tabindex="-1">
      <.segmented_nav label="Time window">
        <:item patch="/?window=7d">7d</:item>
        <:item patch="/?window=30d" active>30d</:item>
      </.segmented_nav>
      <.button>Save</.button>
      <.button navigate="/devices" variant="outline">Devices</.button>
      <.icon_button aria-label="Refresh"><.icon name="hero-arrow-path" /></.icon_button>
      <.badge variant={badge_variant_for("up")}>up</.badge>
      <.panel id="devices-panel">
        <:header>Devices</:header>
        <:actions><.button size="xs">Add</.button></:actions>
        <.surface variant="raised">Inside</.surface>
      </.panel>
      <.alert variant="warning" title="Collector offline">No data.</.alert>
      <.flash kind={:info} flash={%{"info" => "Saved"}} />
      <.modal id="edit-device" on_cancel="close">
        <:title>Edit device</:title>
        Name
        <:actions><.button>Save</.button></:actions>
      </.modal>
      <.tabs aria-label="Views">
        <:tab navigate="/list" active>List</:tab>
        <:tab click="set_view" value="map">Map</:tab>
      </.tabs>
      <.dropdown label="Row actions">
        <:trigger><.icon name="hero-ellipsis-vertical" /></:trigger>
        <:item><button type="button" phx-click="delete">Delete</button></:item>
      </.dropdown>
      <.table id="devices" rows={@rows}>
        <:col :let={row} label="Name">{row.name}</:col>
        <:col :let={row} label="Status">{row.status}</:col>
        <:action :let={row}>
          <button type="button" phx-click="open" phx-value-id={row.id}>Open</button>
        </:action>
      </.table>
      <.pagination current_page={2} total_count={120} page_size={50} result_count={50} />
      <.spinner />
      <.field label="Note" for="note">
        <input id="note" name="note" value="x" />
      </.field>
      <.input field={@form[:email]} type="email" label="Email" />
      <.input field={@form[:role]} type="select" label="Role" options={[{"Admin", "admin"}]} />
      <.input field={@form[:notes]} type="textarea" label="Notes" />
      <.input field={@form[:on]} type="toggle" label="Alerts" />
      <.sparkline values={@values} label="Trend" />
      <.live_sparkline id="rate" values={@values} tone="info" label="Rate" />
      <.area id="cpu" points={@points} interactive timezone="Etc/UTC" time_format="auto" label="CPU" />
      <.bar
        data={[%{label: "eth0", value: 12}, %{label: "eth1", value: 4, tone: "info"}]}
        label="Ports"
      />
      <.donut
        label="Status"
        center_value="5"
        center_label="devices"
        data={[%{label: "Up", value: 4, tone: "success"}, %{label: "Down", value: 1, tone: "danger"}]}
      />
      <.gauge value={72} max={100} unit="percent" warn={70} crit={90} label="Disk" />
      <.world_map
        id="edge-map"
        label="Edges"
        point_event="select_site"
        points={[%{id: "sfo", lon: -122.4, lat: 37.8, label: "SFO"}]}
        regions={[%{id: "840", label: "United States", level: 3}]}
        arcs={[%{id: "hop", from: [-122.4, 37.8], to: [-0.45, 51.47]}]}
      />
    </main>
    <.flash_group flash={%{"info" => "Saved", "error" => "Nope"}} />
    <.footer>
      <:leading>Acme</:leading>
      <:trailing><a href="/status">Status</a></:trailing>
    </.footer>
    """
  end
end
