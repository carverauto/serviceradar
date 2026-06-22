defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.EventHandlers.Builder do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Builder
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Data

  alias AshPhoenix.Form
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.TargetBuilder

  def handle_event("builder_toggle", _params, socket) do
    builder_open = !socket.assigns.builder_open

    socket =
      if builder_open do
        target_query = current_target_query(socket)
        {builder, builder_sync} = TargetBuilder.parse_target_query_to_builder(target_query)

        socket
        |> assign(:builder_open, true)
        |> assign(:builder, builder)
        |> assign(:builder_sync, builder_sync)
      else
        assign(socket, :builder_open, false)
      end

    {:noreply, socket}
  end

  def handle_event("builder_change", %{"builder" => builder_params}, socket) do
    builder = TargetBuilder.update_builder(socket.assigns.builder, builder_params)

    socket =
      socket
      |> assign(:builder, builder)
      |> assign(:builder_sync, true)
      |> maybe_sync_builder_to_form()

    {:noreply, socket}
  end

  def handle_event("builder_add_filter", _params, socket) do
    builder = socket.assigns.builder

    filters =
      builder
      |> Map.get("filters", [])
      |> List.wrap()

    next = TargetBuilder.default_filter()

    updated_builder = Map.put(builder, "filters", filters ++ [next])

    socket =
      socket
      |> assign(:builder, updated_builder)
      |> assign(:builder_sync, true)
      |> maybe_sync_builder_to_form()

    {:noreply, socket}
  end

  def handle_event("builder_remove_filter", %{"idx" => idx_str}, socket) do
    builder = socket.assigns.builder

    filters =
      builder
      |> Map.get("filters", [])
      |> List.wrap()

    index =
      case Integer.parse(idx_str) do
        {i, ""} -> i
        _ -> -1
      end

    updated_filters =
      filters
      |> Enum.with_index()
      |> Enum.reject(fn {_f, i} -> i == index end)
      |> Enum.map(fn {f, _i} -> f end)

    updated_builder = Map.put(builder, "filters", updated_filters)

    socket =
      socket
      |> assign(:builder, updated_builder)
      |> assign(:builder_sync, true)
      |> maybe_sync_builder_to_form()

    {:noreply, socket}
  end

  def handle_event("builder_apply", _params, socket) do
    builder = socket.assigns.builder
    query = TargetBuilder.build_target_query(builder)

    params =
      socket.assigns.ash_form
      |> form_params()
      |> Map.put("target_query", query)

    ash_form = Form.validate(socket.assigns.ash_form, params)

    scope = socket.assigns.current_scope
    device_count = count_target_devices(scope, query)

    {:noreply,
     socket
     |> assign(:ash_form, ash_form)
     |> assign(:form, to_form(ash_form))
     |> assign(:target_device_count, device_count)
     |> assign(:builder_sync, true)}
  end
end
