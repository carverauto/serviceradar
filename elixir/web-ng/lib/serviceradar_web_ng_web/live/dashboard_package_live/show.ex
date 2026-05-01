defmodule ServiceRadarWebNGWeb.DashboardPackageLive.Show do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadar.Integrations.MapboxSettings
  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.Dashboards.FrameRunner
  alias ServiceRadarWebNGWeb.DashboardFrameChannel

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
      |> assign(:query_text, "")
      |> assign(:frame_query_overrides, %{})
      |> assign(:host_payload_json, "{}")

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"route_slug" => route_slug} = params, _uri, socket) do
    overrides = frame_query_overrides(params)

    socket =
      socket
      |> assign(:route_slug, route_slug)
      |> assign(:current_path, "/dashboards/#{route_slug}")
      |> assign(:frame_query_overrides, overrides)
      |> assign(:load_state, :loading)

    socket =
      if connected?(socket) do
        scope = socket.assigns.current_scope

        start_async(socket, :dashboard_package_load, fn ->
          load_dashboard_package(route_slug, scope, overrides)
        end)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("run_query", %{"query" => %{"q" => query}}, socket) do
    query = String.trim(to_string(query || ""))

    to =
      if query == "" do
        ~p"/dashboards/#{socket.assigns.route_slug}"
      else
        ~p"/dashboards/#{socket.assigns.route_slug}?#{[q: query]}"
      end

    {:noreply, push_patch(socket, to: to)}
  end

  @impl true
  def handle_async(
        :dashboard_package_load,
        {:ok, {:ok, %DashboardInstance{} = instance, data_frames, frames, mapbox}},
        socket
      ) do
    package = instance.dashboard_package

    socket =
      socket
      |> assign(:load_state, :ready)
      |> assign(:instance, instance)
      |> assign(:package, package)
      |> assign(:page_title, instance.name)
      |> assign(:query_text, first_frame_query(data_frames))
      |> assign(:host_payload_json, Jason.encode!(host_payload(instance, package, data_frames, frames, mapbox)))

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

            <div class="flex w-full flex-col gap-2 sm:w-auto sm:min-w-[32rem] sm:flex-row sm:items-center">
              <.form for={%{}} as={:query} phx-submit="run_query" class="join w-full">
                <input
                  type="search"
                  name="query[q]"
                  value={@query_text}
                  class="input input-sm input-bordered join-item w-full font-mono text-xs"
                  aria-label="Dashboard SRQL query"
                />
                <button type="submit" class="btn btn-sm btn-primary join-item">Run</button>
              </.form>
              <.link navigate={~p"/dashboard"} class="btn btn-ghost btn-sm">Dashboard</.link>
            </div>
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

  defp load_dashboard_package(route_slug, scope, overrides) do
    with {:ok, %DashboardInstance{} = instance} <-
           Dashboards.get_enabled_instance_by_slug(route_slug, scope: scope) do
      package = instance.dashboard_package
      data_frames = apply_frame_query_overrides(package.data_frames || [], overrides)
      frames = FrameRunner.run(data_frames, scope)
      mapbox = read_mapbox(scope)
      {:ok, instance, data_frames, frames, mapbox}
    end
  end

  defp host_payload(%DashboardInstance{} = instance, %DashboardPackage{} = package, data_frames, frames, mapbox) do
    %{
      "host" => %{
        "version" => "dashboard-host-v1",
        "interface_version" => package.renderer["interface_version"] || "dashboard-wasm-v1"
      },
      "data_provider" => %{
        "version" => "dashboard-data-v1",
        "frames" => Enum.map(frames, &frame_summary/1),
        "stream_topic" => "dashboards:#{instance.route_slug}",
        "stream_token" => DashboardFrameChannel.stream_token(instance.route_slug, data_frames),
        "refresh_interval_ms" => 15_000
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
        "data_frames" => data_frames,
        "frames" => frames,
        "renderer_url" => ~p"/dashboard-packages/#{package.id}/renderer?v=#{package.content_hash}",
        "wasm_url" => ~p"/dashboard-packages/#{package.id}/renderer.wasm?v=#{package.content_hash}"
      }
    }
  end

  defp frame_query_overrides(params) do
    q = params |> Map.get("q", "") |> to_string() |> String.trim()

    params
    |> Enum.reduce(%{}, fn
      {"frame_" <> frame_id, value}, acc ->
        value = value |> to_string() |> String.trim()
        if frame_id != "" and value != "", do: Map.put(acc, frame_id, value), else: acc

      _other, acc ->
        acc
    end)
    |> maybe_put_first_query(q)
  end

  defp maybe_put_first_query(overrides, ""), do: overrides
  defp maybe_put_first_query(overrides, query), do: Map.put(overrides, "__first__", query)

  defp apply_frame_query_overrides(data_frames, overrides) when is_list(data_frames) do
    data_frames
    |> Enum.with_index()
    |> Enum.map(fn {frame, index} ->
      frame_id = frame_id(frame)
      query = Map.get(overrides, frame_id) || if(index == 0, do: Map.get(overrides, "__first__"))

      if is_binary(query) and query != "" do
        Map.put(frame, "query", query)
      else
        frame
      end
    end)
  end

  defp apply_frame_query_overrides(_data_frames, _overrides), do: []

  defp frame_id(%{"id" => id}) when is_binary(id), do: id
  defp frame_id(%{id: id}) when is_binary(id), do: id
  defp frame_id(_frame), do: ""

  defp first_frame_query([%{"query" => query} | _]) when is_binary(query), do: query
  defp first_frame_query([%{query: query} | _]) when is_binary(query), do: query
  defp first_frame_query(_data_frames), do: ""

  defp frame_summary(frame) when is_map(frame) do
    %{
      "id" => frame["id"],
      "status" => frame["status"],
      "encoding" => frame["encoding"],
      "requested_encoding" => frame["requested_encoding"],
      "row_count" => frame |> Map.get("results", []) |> row_count(),
      "byte_length" => Map.get(frame, "byte_length")
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
