defmodule ServiceRadarUIExample.GalleryLive do
  @moduledoc false

  use Phoenix.LiveView, layout: false
  use ServiceRadarUI

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       now: ~U[2026-11-27 12:00:00Z],
       values: [1, 3, 2, 5, 4, 6],
       page: 2,
       view: "list",
       rows: [%{id: "edge-a", name: "edge-a", status: "up"}],
       form:
         to_form(
           %{"email" => "ada@example.com", "role" => "admin", "notes" => "hi", "on" => "true"},
           as: :user
         )
     )}
  end

  @impl true
  def handle_event("close", _params, socket), do: {:noreply, socket}

  def handle_event("paginate", %{"page" => page}, socket) do
    {:noreply, assign(socket, :page, String.to_integer(page))}
  end

  def handle_event("set_view", %{"tab" => view}, socket) do
    {:noreply, assign(socket, :view, view)}
  end

  def handle_event("validate", %{"user" => params}, socket) when is_map(params) do
    {:noreply, assign(socket, :form, to_form(params, as: :user))}
  end

  def handle_event("save", %{"user" => params}, socket) when is_map(params) do
    {:noreply, put_flash(assign(socket, :form, to_form(params, as: :user)), :info, "Saved")}
  end

  def handle_event(event, %{"id" => id}, socket)
      when event in ["select_site", "select_region", "select_arc", "open", "delete"] do
    {:noreply, put_flash(socket, :info, id)}
  end

  @impl true
  def render(assigns) do
    points = for i <- 0..5, do: {DateTime.add(assigns.now, i * 3600, :second), i * 2.0}
    assigns = assign(assigns, :points, points)

    ~H"""
    <.skip_link />
    <.top_bar>
      <:brand>Acme</:brand>
      <:nav><a href="/devices">Devices</a></:nav>
      <:actions><.theme_toggle /></:actions>
    </.top_bar>
    <main id="main" tabindex="-1">
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
        <:tab navigate="/list" active={@view == "list"}>List</:tab>
        <:tab click="set_view" value="map" active={@view == "map"}>Map</:tab>
      </.tabs>
      <.dropdown label="Row actions">
        <:trigger><.icon name="hero-ellipsis-vertical" /></:trigger>
        <:item><button type="button" phx-click="delete" phx-value-id="edge-a">Delete</button></:item>
      </.dropdown>
      <.table id="devices" rows={@rows}>
        <:col :let={row} label="Name">{row.name}</:col>
        <:col :let={row} label="Status">{row.status}</:col>
        <:action :let={row}>
          <button type="button" phx-click="open" phx-value-id={row.id}>Open</button>
        </:action>
      </.table>
      <.pagination current_page={@page} total_count={120} page_size={50} result_count={50} />
      <.spinner />
      <.field label="Note" for="note">
        <input id="note" name="note" value="x" />
      </.field>
      <form phx-change="validate" phx-submit="save">
        <.input field={@form[:email]} type="email" label="Email" />
        <.input field={@form[:role]} type="select" label="Role" options={[{"Admin", "admin"}]} />
        <.input field={@form[:notes]} type="textarea" label="Notes" />
        <.input field={@form[:on]} type="toggle" label="Alerts" />
        <.button type="submit">Save form</.button>
      </form>
      <.sparkline values={@values} label="Trend" />
      <.live_sparkline id="rate" values={@values} tone="info" label="Rate" />
      <.area
        id="cpu"
        points={@points}
        interactive
        timezone="Etc/UTC"
        time_format="auto"
        label="CPU"
      />
      <.bar
        data={[%{label: "eth0", value: 12}, %{label: "eth1", value: 4, tone: "info"}]}
        label="Ports"
      />
      <.donut
        label="Status"
        center_value="5"
        center_label="devices"
        data={[
          %{label: "Up", value: 4, tone: "success"},
          %{label: "Down", value: 1, tone: "danger"}
        ]}
      />
      <.gauge value={72} max={100} unit="percent" warn={70} crit={90} label="Disk" />
      <.world_map
        id="edge-map"
        label="Edges"
        point_event="select_site"
        region_event="select_region"
        arc_event="select_arc"
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
