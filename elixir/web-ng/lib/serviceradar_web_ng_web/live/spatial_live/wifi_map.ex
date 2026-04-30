defmodule ServiceRadarWebNGWeb.SpatialLive.WifiMap do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Integrations.MapboxSettings
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_limit 250
  @max_limit 1_000
  @wifi_map_path "/spatial/wifi-map"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "WiFi Map")
     |> assign(:current_path, @wifi_map_path)
     |> assign(:wifi_rows, [])
     |> assign(:wifi_map_sites, [])
     |> assign(:wifi_map_sites_json, "[]")
     |> assign(:mapbox, nil)
     |> SRQLPage.init("wifi_sites", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket =
      socket
      |> assign(:current_path, @wifi_map_path)
      |> assign(:mapbox, read_mapbox(socket.assigns.current_scope.user))
      |> SRQLPage.load_list(params, uri, :wifi_rows,
        default_limit: @default_limit,
        max_limit: @max_limit
      )
      |> assign_map_sites()

    {:noreply, socket}
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_submit", params,
       fallback_path: @wifi_map_path,
       limit_assign_key: :limit
     )}
  end

  def handle_event("srql_builder_toggle", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_toggle", params,
       entity: "wifi_sites",
       fallback_path: @wifi_map_path,
       limit_assign_key: :limit
     )}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", params)}
  end

  def handle_event("srql_builder_run", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_run", params,
       entity: "wifi_sites",
       fallback_path: @wifi_map_path,
       limit_assign_key: :limit
     )}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "wifi_sites")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "wifi_sites")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="sr-wifi-map-page mx-auto max-w-[96rem] p-6 space-y-5">
        <div class="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
          <div>
            <h1 class="sr-spatial-title">WiFi Map</h1>
            <p class="sr-spatial-subtitle">
              SRQL-backed geographic view of WiFi sites, access points, controllers, RADIUS mappings, and fleet history.
            </p>
          </div>

          <div class="flex flex-wrap items-center gap-2">
            <.link navigate={~p"/spatial"} class="btn btn-sm">
              <.icon name="hero-map" class="size-4" /> Spatial
            </.link>
            <.link navigate={~p"/spatial/field-surveys"} class="btn btn-sm">
              <.icon name="hero-rectangle-stack" class="size-4" /> FieldSurvey
            </.link>
          </div>
        </div>

        <.ui_panel>
          <:header>
            <div class="flex min-w-0 flex-1 flex-col gap-3 xl:flex-row xl:items-center xl:justify-between">
              <div class="min-w-0">
                <div class="text-sm font-semibold">Map Query</div>
                <div class="text-xs text-base-content/70">
                  {@srql.query}
                </div>
              </div>

              <.srql_query_bar
                query={@srql.query}
                draft={@srql.draft}
                loading={@srql.loading}
                builder_available={@srql.builder_available}
                builder_open={@srql.builder_open}
                builder_supported={@srql.builder_supported}
                builder_sync={@srql.builder_sync}
                builder={@srql.builder}
              />
            </div>
          </:header>

          <div :if={@srql.builder_open} class="mb-4">
            <.srql_query_builder
              supported={@srql.builder_supported}
              sync={@srql.builder_sync}
              builder={@srql.builder}
            />
          </div>

          <div :if={@srql.error} class="alert alert-error mb-4 text-sm">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <span>{@srql.error}</span>
          </div>

          <div class="grid gap-4 xl:grid-cols-[minmax(0,2fr)_minmax(20rem,0.8fr)]">
            <div class="sr-wifi-map-stage">
              <div
                id="wifi-site-map"
                phx-hook="WifiSiteMap"
                phx-update="ignore"
                data-sites={@wifi_map_sites_json}
                data-enabled={mapbox_enabled?(@mapbox)}
                data-access-token={mapbox_access_token(@mapbox)}
                data-style-light={mapbox_style_light(@mapbox)}
                data-style-dark={mapbox_style_dark(@mapbox)}
                class="sr-wifi-map-canvas"
              >
              </div>
            </div>

            <div class="grid gap-3 content-start">
              <div class="stats stats-vertical border border-base-300 bg-base-100 shadow-sm">
                <div class="stat">
                  <div class="stat-title">Rows</div>
                  <div class="stat-value text-2xl">{length(@wifi_rows)}</div>
                </div>
                <div class="stat">
                  <div class="stat-title">Mappable</div>
                  <div class="stat-value text-2xl">{length(@wifi_map_sites)}</div>
                </div>
                <div class="stat">
                  <div class="stat-title">Limit</div>
                  <div class="stat-value text-2xl">{@limit}</div>
                </div>
              </div>

              <div class="rounded-lg border border-base-300 bg-base-100 p-4 text-sm text-base-content/70">
                Mapbox provides the basemap. WiFi features are rendered as a deck.gl layer from the current SRQL result set.
              </div>
            </div>
          </div>
        </.ui_panel>

        <.ui_panel>
          <:header>
            <div>
              <div class="text-sm font-semibold">SRQL Results</div>
              <div class="text-xs text-base-content/70">
                Result rows backing the current map view.
              </div>
            </div>
          </:header>

          <.srql_results_table
            id="wifi-map-results"
            rows={@wifi_rows}
            columns={[
              "site_code",
              "name",
              "region",
              "ap_count",
              "up_count",
              "down_count",
              "wlc_count",
              "server_group",
              "cluster",
              "collection_timestamp"
            ]}
            empty_message="No WiFi map rows match this SRQL query."
          />
        </.ui_panel>
      </div>
    </Layouts.app>
    """
  end

  defp assign_map_sites(socket) do
    sites = socket.assigns.wifi_rows |> Enum.map(&map_site/1) |> Enum.filter(& &1)

    socket
    |> assign(:wifi_map_sites, sites)
    |> assign(:wifi_map_sites_json, Jason.encode!(sites))
  end

  defp map_site(%{} = row) do
    with {:ok, lat} <- latitude(row["latitude"] || row["lat"]),
         {:ok, lng} <- longitude(row["longitude"] || row["lng"] || row["lon"]) do
      %{
        feature_id: string_value(row["feature_id"] || row["id"] || row["site_code"]),
        site_code: string_value(row["site_code"]),
        name: string_value(row["name"] || row["site_name"]),
        region: string_value(row["region"]),
        site_type: string_value(row["site_type"]),
        latitude: lat,
        longitude: lng,
        ap_count: int_value(row["ap_count"]),
        up_count: int_value(row["up_count"]),
        down_count: int_value(row["down_count"]),
        wlc_count: int_value(row["wlc_count"]),
        server_group: string_value(row["server_group"]),
        cluster: string_value(row["cluster"]),
        aaa_profile: string_value(row["aaa_profile"]),
        collection_timestamp: string_value(row["collection_timestamp"])
      }
    else
      _ -> nil
    end
  end

  defp map_site(_), do: nil

  defp latitude(value) do
    case finite_float(value) do
      {:ok, lat} when lat >= -90.0 and lat <= 90.0 -> {:ok, lat}
      _ -> :error
    end
  end

  defp longitude(value) do
    case finite_float(value) do
      {:ok, lng} when lng >= -180.0 and lng <= 180.0 -> {:ok, lng}
      _ -> :error
    end
  end

  defp finite_float(value) when is_float(value), do: {:ok, value}

  defp finite_float(value) when is_integer(value), do: finite_float(value / 1)

  defp finite_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> finite_float(float)
      _ -> :error
    end
  end

  defp finite_float(_), do: :error

  defp int_value(value) when is_integer(value), do: value

  defp int_value(value) when is_float(value), do: round(value)

  defp int_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> 0
    end
  end

  defp int_value(_), do: 0

  defp string_value(nil), do: ""
  defp string_value(value) when is_binary(value), do: value
  defp string_value(value), do: to_string(value)

  defp read_mapbox(nil), do: nil

  defp read_mapbox(user) do
    case MapboxSettings.get_settings(actor: user) do
      {:ok, %MapboxSettings{} = settings} -> settings
      _ -> nil
    end
  end

  defp mapbox_enabled?(%MapboxSettings{} = settings), do: settings.enabled
  defp mapbox_enabled?(_), do: false

  defp mapbox_access_token(%MapboxSettings{} = settings), do: settings.access_token || ""
  defp mapbox_access_token(_), do: ""

  defp mapbox_style_light(%MapboxSettings{} = settings), do: settings.style_light || "mapbox://styles/mapbox/light-v11"

  defp mapbox_style_light(_), do: "mapbox://styles/mapbox/light-v11"

  defp mapbox_style_dark(%MapboxSettings{} = settings), do: settings.style_dark || "mapbox://styles/mapbox/dark-v11"

  defp mapbox_style_dark(_), do: "mapbox://styles/mapbox/dark-v11"
end
