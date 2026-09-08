defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Builder do
  @moduledoc false
  import Phoenix.Component, only: [assign: 3, to_form: 1]
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Data

  alias AshPhoenix.Form
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.TargetBuilder

  def maybe_sync_builder_to_form(socket) do
    if socket.assigns.builder_sync do
      builder = socket.assigns.builder
      query = TargetBuilder.build_target_query(builder)

      params =
        socket.assigns.ash_form
        |> form_params()
        |> Map.put("target_query", query)

      ash_form = Form.validate(socket.assigns.ash_form, params)

      # Only re-run the (live SRQL) device count when the built target query
      # actually changed — the form's phx-debounce fires builder_change on
      # every field edit, but most edits (e.g. toggles that don't affect the
      # query) leave the query string identical. Memoizing on the query avoids
      # a redundant count round-trip per keystroke.
      socket =
        socket
        |> assign(:ash_form, ash_form)
        |> assign(:form, to_form(ash_form))

      previous_query = Map.get(socket.assigns, :last_target_query)
      socket = assign(socket, :last_target_query, query)

      if previous_query == query do
        socket
      else
        scope = socket.assigns.current_scope
        device_count = count_target_devices(scope, query)
        assign(socket, :target_device_count, device_count)
      end
    else
      socket
    end
  end

  def normalize_static_targets(params) when is_map(params) do
    case Map.get(params, "static_targets") do
      nil ->
        params

      targets when is_list(targets) ->
        Map.put(params, "static_targets", Enum.map(targets, &String.trim/1))

      targets when is_binary(targets) ->
        parsed =
          targets
          |> String.split(~r/[\n,]+/, trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        Map.put(params, "static_targets", parsed)

      _ ->
        params
    end
  end

  def form_params(ash_form) do
    ash_form
    |> Form.params()
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  def current_target_query(socket) do
    case Phoenix.HTML.Form.input_value(socket.assigns.form, :target_query) do
      value when is_binary(value) -> value
      value when is_list(value) -> to_string(value)
      _ -> ""
    end
  end
end
