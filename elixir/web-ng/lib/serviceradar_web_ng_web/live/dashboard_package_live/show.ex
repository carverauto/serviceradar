defmodule ServiceRadarWebNGWeb.DashboardPackageLive.Show do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadar.Integrations.MapboxSettings
  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.Dashboards.FrameRunner

  @impl true
  def mount(%{"route_slug" => route_slug}, _session, socket) do
    socket =
      socket
      |> assign(:route_slug, route_slug)
      |> assign(:current_path, "/dashboards/#{route_slug}")
      |> assign(:page_title, "Dashboard")
      |> assign(:load_state, :loading)
      |> assign(:instance, nil)
      |> assign(:package, nil)
      |> assign(:host_payload_json, "{}")

    socket =
      if connected?(socket) do
        scope = socket.assigns.current_scope

        start_async(socket, :dashboard_package_load, fn ->
          with {:ok, %DashboardInstance{} = instance} <-
                 Dashboards.get_enabled_instance_by_slug(route_slug, scope: scope) do
            package = instance.dashboard_package
            frames = FrameRunner.run(package.data_frames || [], scope)
            mapbox = read_mapbox(scope)
            {:ok, instance, frames, mapbox}
          end
        end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_async(:dashboard_package_load, {:ok, {:ok, %DashboardInstance{} = instance, frames, mapbox}}, socket) do
    package = instance.dashboard_package

    socket =
      socket
      |> assign(:load_state, :ready)
      |> assign(:instance, instance)
      |> assign(:package, package)
      |> assign(:page_title, instance.name)
      |> assign(:host_payload_json, Jason.encode!(host_payload(instance, package, frames, mapbox)))

    {:noreply, socket}
  end

  def handle_async(:dashboard_package_load, {:ok, {:error, :not_found}}, socket) do
    {:noreply, assign(socket, :load_state, :not_found)}
  end

  def handle_async(:dashboard_package_load, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> assign(:load_state, :error) |> assign(:load_error, inspect(reason))}
  end

  def handle_async(:dashboard_package_load, {:exit, reason}, socket) do
    {:noreply, socket |> assign(:load_state, :error) |> assign(:load_error, inspect(reason))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      shell={:operations}
      hide_breadcrumb
      srql={%{enabled: false, page_path: @current_path}}
    >
      <div class="min-h-[calc(100vh-5rem)] bg-base-100">
        <div :if={@load_state == :loading} class="flex min-h-[28rem] items-center justify-center">
          <span class="loading loading-spinner loading-lg text-primary"></span>
        </div>

        <div
          :if={@load_state == :not_found}
          class="mx-auto flex min-h-[28rem] max-w-2xl flex-col items-center justify-center gap-3 px-6 text-center"
        >
          <div class="text-lg font-semibold">Dashboard package unavailable</div>
          <p class="text-sm text-base-content/70">
            This dashboard is not enabled, has not been verified, or no longer exists.
          </p>
          <.link navigate={~p"/dashboard"} class="btn btn-primary btn-sm">Back to dashboard</.link>
        </div>

        <div
          :if={@load_state == :error}
          class="mx-auto flex min-h-[28rem] max-w-2xl flex-col items-center justify-center gap-3 px-6 text-center"
        >
          <div class="text-lg font-semibold">Dashboard package failed to load</div>
          <p class="text-sm text-base-content/70">{@load_error}</p>
          <.link navigate={~p"/dashboard"} class="btn btn-primary btn-sm">Back to dashboard</.link>
        </div>

        <section :if={@load_state == :ready} class="flex min-h-[calc(100vh-5rem)] flex-col">
          <header class="flex flex-col gap-3 border-b border-base-300 bg-base-100 px-4 py-3 sm:flex-row sm:items-center sm:justify-between lg:px-6">
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <h1 class="truncate text-base font-semibold">{@instance.name}</h1>
                <span class="badge badge-outline">{@package.version}</span>
                <span :if={@package.vendor} class="badge badge-ghost">{@package.vendor}</span>
              </div>
              <p class="mt-1 text-xs text-base-content/60">
                Browser WASM dashboard package
              </p>
            </div>

            <.link navigate={~p"/dashboard"} class="btn btn-ghost btn-sm">Dashboard</.link>
          </header>

          <div
            id={"dashboard-package-host-#{@instance.id}"}
            phx-hook="DashboardWasmHost"
            phx-update="ignore"
            data-host={@host_payload_json}
            class="relative min-h-[calc(100vh-10rem)] flex-1 bg-base-100"
          >
            <div class="absolute inset-0 flex items-center justify-center">
              <div class="text-center">
                <span class="loading loading-spinner loading-md text-primary"></span>
                <div class="mt-3 text-sm text-base-content/70">Loading dashboard renderer</div>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp host_payload(%DashboardInstance{} = instance, %DashboardPackage{} = package, frames, mapbox) do
    %{
      "host" => %{
        "version" => "dashboard-host-v1",
        "interface_version" => package.renderer["interface_version"] || "dashboard-wasm-v1"
      },
      "data_provider" => %{
        "version" => "dashboard-data-v1",
        "frames" => Enum.map(frames, &frame_summary/1)
      },
      "mapbox" => %{
        "enabled" => mapbox_enabled?(mapbox),
        "access_token" => mapbox_access_token(mapbox),
        "style_light" => mapbox_style_light(mapbox),
        "style_dark" => mapbox_style_dark(mapbox)
      },
      "instance" => %{
        "id" => instance.id,
        "name" => instance.name,
        "route_slug" => instance.route_slug,
        "placement" => Atom.to_string(instance.placement),
        "settings" => instance.settings || %{}
      },
      "package" => %{
        "id" => package.id,
        "dashboard_id" => package.dashboard_id,
        "name" => package.name,
        "version" => package.version,
        "vendor" => package.vendor,
        "capabilities" => package.capabilities || [],
        "renderer" => package.renderer || %{},
        "data_frames" => package.data_frames || [],
        "frames" => frames,
        "wasm_url" => ~p"/dashboard-packages/#{package.id}/renderer.wasm?v=#{package.content_hash}"
      }
    }
  end

  defp frame_summary(frame) when is_map(frame) do
    %{
      "id" => frame["id"],
      "status" => frame["status"],
      "encoding" => frame["encoding"],
      "requested_encoding" => frame["requested_encoding"],
      "row_count" => frame |> Map.get("results", []) |> row_count()
    }
  end

  defp frame_summary(_frame), do: %{"id" => nil, "status" => "error", "row_count" => 0}

  defp row_count(results) when is_list(results), do: length(results)
  defp row_count(_results), do: 0

  defp read_mapbox(nil), do: nil

  defp read_mapbox(scope) do
    case MapboxSettings.get_settings(scope: scope) do
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

  defp mapbox_style_light(%MapboxSettings{} = settings) do
    settings.style_light || "mapbox://styles/mapbox/light-v11"
  end

  defp mapbox_style_light(_), do: "mapbox://styles/mapbox/light-v11"

  defp mapbox_style_dark(%MapboxSettings{} = settings) do
    settings.style_dark || "mapbox://styles/mapbox/dark-v11"
  end

  defp mapbox_style_dark(_), do: "mapbox://styles/mapbox/dark-v11"
end
