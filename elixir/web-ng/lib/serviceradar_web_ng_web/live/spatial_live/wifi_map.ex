defmodule ServiceRadarWebNGWeb.SpatialLive.WifiMap do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Integrations.MapboxSettings
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_limit 250
  @max_limit 1_000
  @wifi_map_path "/network-map"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Network Asset Map")
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
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      srql={@srql}
      hide_breadcrumb
    >
      <div class="flex min-h-[calc(100vh-4rem)] flex-col gap-3 bg-base-100 p-3 text-base-content lg:p-4">
        <header class="flex flex-col gap-3 xl:flex-row xl:items-center xl:justify-between">
          <div class="flex items-center gap-3">
            <.ui_icon_button
              navigate={~p"/dashboard"}
              variant="ghost"
              size="sm"
              aria-label="Back to dashboard"
            >
              <.icon name="hero-arrow-left" class="size-5" />
            </.ui_icon_button>
            <div>
              <h1 class="text-lg font-semibold leading-tight">Network Asset Map</h1>
              <p class="text-sm text-base-content/60">
                SRQL-driven view of network assets with location data.
              </p>
            </div>
          </div>

          <div class="stats stats-vertical border border-base-300 bg-base-200/60 shadow-sm sm:stats-horizontal">
            <.wifi_kpi label="Locations" value={format_count(length(@wifi_map_sites))} />
            <.wifi_kpi
              label="Wireless APs"
              value={format_count(wifi_sum(@wifi_map_sites, :ap_count))}
            />
            <.wifi_kpi
              label="Up"
              value={format_count(wifi_sum(@wifi_map_sites, :up_count))}
              tone="good"
            />
            <.wifi_kpi
              label="Down"
              value={format_count(wifi_sum(@wifi_map_sites, :down_count))}
              tone="bad"
            />
            <.wifi_kpi
              label="Controllers"
              value={format_count(wifi_sum(@wifi_map_sites, :wlc_count))}
            />
            <.wifi_kpi label="Regions" value={format_count(wifi_region_count(@wifi_map_sites))} />
          </div>
        </header>

        <div class="grid min-h-0 flex-1 gap-3 lg:grid-cols-[20rem_minmax(0,1fr)]">
          <aside class="card min-h-0 border border-base-300 bg-base-100 shadow-sm">
            <div class="card-body gap-4 p-4">
              <div>
                <h2 class="card-title text-sm">Result Breakdown</h2>
                <p class="text-xs text-base-content/60">
                  Filtering is controlled by the SRQL bar at the top of the page.
                </p>
              </div>
              <.wifi_chip_group
                title={"Regions #{format_count(wifi_sum(@wifi_map_sites, :ap_count))}"}
                chips={wifi_region_chips(@wifi_map_sites)}
              />
              <.wifi_chip_group
                title={"CPPM Clusters #{format_count(length(@wifi_map_sites))}"}
                chips={wifi_value_chips(@wifi_map_sites, :cluster)}
              />
              <.wifi_chip_group
                title="WLC Models"
                chips={wifi_breakdown_chips(@wifi_map_sites, :wlc_model_breakdown)}
              />
              <.wifi_chip_group
                title="AOS Versions"
                chips={wifi_breakdown_chips(@wifi_map_sites, :aos_version_breakdown)}
              />
              <.wifi_chip_group title="AP Families" chips={wifi_family_chips(@wifi_map_sites)} />

              <div class="flex items-center justify-between gap-3 text-xs font-semibold uppercase tracking-wide text-base-content/60">
                <span>Locations ({length(@wifi_map_sites)})</span>
                <span>{format_count(wifi_sum(@wifi_map_sites, :ap_count))} wireless APs</span>
              </div>
              <div class="grid max-h-[22rem] gap-1 overflow-y-auto pr-1">
                <button
                  :for={site <- Enum.take(@wifi_map_sites, 40)}
                  type="button"
                  class="btn btn-ghost btn-sm h-auto min-h-10 justify-between rounded-md px-2 text-left normal-case"
                >
                  <span class="truncate">
                    <strong class="font-semibold text-base-content">{site_label(site)}</strong>
                    <span class="text-base-content/50"> ·     {site.region}</span>
                  </span>
                  <span class="badge badge-ghost badge-sm">{format_count(site.ap_count)}</span>
                </button>
              </div>
            </div>
          </aside>

          <main class="card min-h-[34rem] overflow-hidden border border-base-300 bg-base-100 shadow-sm lg:min-h-0">
            <div :if={@srql.error} class="alert alert-error rounded-none">
              <.icon name="hero-exclamation-triangle" class="size-5" />
              <span>{@srql.error}</span>
            </div>

            <div class="relative min-h-[34rem] flex-1 overflow-hidden bg-base-200 lg:min-h-0">
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
          </main>
        </div>
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

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:tone, :string, default: nil)

  defp wifi_kpi(assigns) do
    ~H"""
    <div class="stat px-4 py-2">
      <div class="stat-title text-xs">{@label}</div>
      <div class={[
        "stat-value text-xl",
        @tone == "good" && "text-success",
        @tone == "bad" && "text-error"
      ]}>
        {@value}
      </div>
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:chips, :list, required: true)

  defp wifi_chip_group(assigns) do
    ~H"""
    <div class="grid gap-2">
      <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">{@title}</h3>
      <div class="flex flex-wrap gap-1.5">
        <span :for={chip <- @chips} class="badge badge-outline gap-1.5">
          <span class="size-2 rounded-full" style={"background: #{chip.color};"}></span>{chip.label}
        </span>
      </div>
    </div>
    """
  end

  defp wifi_region_chips(sites) do
    palette = ["#00d48f", "#ffad2f", "#3da2ff", "#b96cff", "#ff6c80"]

    sites
    |> Enum.map(& &1.region)
    |> Enum.reject(&(&1 == ""))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_region, count} -> -count end)
    |> Enum.take(8)
    |> Enum.with_index()
    |> Enum.map(fn {{region, _count}, index} ->
      %{label: region, color: Enum.at(palette, rem(index, length(palette)))}
    end)
  end

  defp wifi_value_chips(sites, key) do
    sites
    |> Enum.map(&Map.get(&1, key, ""))
    |> Enum.reject(&(&1 == ""))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_value, count} -> -count end)
    |> Enum.take(8)
    |> Enum.with_index()
    |> Enum.map(fn {{value, _count}, index} -> %{label: value, color: palette_color(index)} end)
  end

  defp wifi_breakdown_chips(sites, key) do
    sites
    |> Enum.flat_map(fn site ->
      site
      |> Map.get(key, %{})
      |> map_entries()
    end)
    |> Enum.reduce(%{}, fn {label, count}, acc -> Map.update(acc, label, count, &(&1 + count)) end)
    |> Enum.sort_by(fn {_label, count} -> -count end)
    |> Enum.take(8)
    |> Enum.with_index()
    |> Enum.map(fn {{label, _count}, index} -> %{label: label, color: palette_color(index)} end)
  end

  defp wifi_family_chips(sites) do
    sites
    |> Enum.flat_map(fn site ->
      site
      |> Map.get(:model_breakdown, %{})
      |> map_entries()
      |> Enum.map(fn {model, count} -> {model_family(model), count} end)
    end)
    |> Enum.reduce(%{}, fn {label, count}, acc -> Map.update(acc, label, count, &(&1 + count)) end)
    |> Enum.sort_by(fn {_label, count} -> -count end)
    |> Enum.take(8)
    |> Enum.with_index()
    |> Enum.map(fn {{label, _count}, index} -> %{label: label, color: palette_color(index)} end)
  end

  defp palette_color(index) do
    Enum.at(["#00d48f", "#ffad2f", "#3da2ff", "#b96cff", "#ff6c80"], rem(index, 5))
  end

  defp map_entries(value) when is_map(value) do
    Enum.flat_map(value, fn {label, count} ->
      count = int_value(count)
      if count > 0, do: [{to_string(label), count}], else: []
    end)
  end

  defp map_entries(_value), do: []

  defp model_family(model) do
    case Regex.run(~r/\d/, to_string(model)) do
      [digit] -> "#{digit}XX"
      _ -> to_string(model)
    end
  end

  defp wifi_sum(sites, key) do
    sites
    |> Enum.map(&Map.get(&1, key, 0))
    |> Enum.sum()
  end

  defp site_label(%{site_code: code, name: name}) do
    Enum.find([code, name], &(is_binary(&1) and &1 != "")) || "Wireless site"
  end

  defp wifi_region_count(sites) do
    sites
    |> Enum.map(& &1.region)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> length()
  end

  defp format_count(value) when is_integer(value), do: value |> Integer.to_string() |> delimit_integer_string()
  defp format_count(value), do: value |> int_value() |> Integer.to_string() |> delimit_integer_string()

  defp delimit_integer_string(value) do
    value
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
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
        model_breakdown: map_value(row["model_breakdown"]),
        wlc_count: int_value(row["wlc_count"]),
        wlc_model_breakdown: map_value(row["wlc_model_breakdown"]),
        aos_version_breakdown: map_value(row["aos_version_breakdown"]),
        controller_names: list_value(row["controller_names"]),
        server_group: string_value(row["server_group"]),
        cluster: string_value(row["cluster"]),
        all_server_groups: list_value(row["all_server_groups"]),
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

  defp map_value(value) when is_map(value), do: value
  defp map_value(_value), do: %{}

  defp list_value(value) when is_list(value), do: value
  defp list_value(_value), do: []

  defp read_mapbox(nil), do: nil

  defp read_mapbox(user) do
    case MapboxSettings.get_settings(actor: user) do
      {:ok, %MapboxSettings{} = settings} -> settings
      _ -> nil
    end
  rescue
    _ -> nil
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
