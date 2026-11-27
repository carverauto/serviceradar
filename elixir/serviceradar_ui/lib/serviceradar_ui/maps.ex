defmodule ServiceRadarUI.Maps do
  @moduledoc """
  An offline world map rendered by the `SrWorldMap` hook.

  The hook draws country outlines from the Natural Earth 1:110m topology the
  package ships in `priv/static/world-110m.json`. It is fetched once from your
  own origin (lazy, on first mount), so the map needs no tile server, token or
  third-party origin and works under `connect-src 'self'`.

  Serve the package's static files, for example in your endpoint:

      plug Plug.Static,
        at: "/serviceradar_ui",
        from: {:serviceradar_ui, "priv/static"},
        only: ~w(world-110m.json serviceradar_ui.js serviceradar_ui.js.map theme_init.js)

  Three layers take data as JSON in `data-*` attributes, re-read whenever the
  server re-renders them, or pushed later with `ServiceRadarUI.push_update/3`:

    * `points` - `%{id:, lon:, lat:, label:, tone:, size:}`; `size` is 1-5.
    * `regions` - `%{id:, label:, tone:, level:}`, where `id` is the ISO 3166-1
      numeric code (`"840"`) or the Natural Earth country name; `level` (1-5)
      sets the fill strength.
    * `arcs` - `%{id:, from: [lon, lat], to: [lon, lat], label:, tone:, weight:}`;
      `weight` is 1-5.

  When `point_event`, `region_event` or `arc_event` is set, clicking a feature
  pushes that event with `%{"id" => id}`.
  """

  use Phoenix.Component

  @projections ~w(equirectangular natural-earth)

  @doc """
  Renders the map container. The hook owns the SVG, so that element is
  `phx-update="ignore"`. LiveView still patches the figure's `data-*`
  attributes (which calls `updated/0`), and `ServiceRadarUI.push_update/3`
  reaches the same hook without a re-render.

      <.world_map
        id="edge-map"
        label="Edge sites"
        points={Enum.map(@sites, &%{id: &1.id, lon: &1.lon, lat: &1.lat, label: &1.name})}
        point_event="select_site"
      />
  """
  attr :id, :string, required: true
  attr :points, :list, default: []
  attr :regions, :list, default: []
  attr :arcs, :list, default: []
  attr :projection, :string, default: "natural-earth", values: @projections
  attr :topology_url, :string, default: "/serviceradar_ui/world-110m.json"
  attr :point_event, :string, default: nil
  attr :region_event, :string, default: nil
  attr :arc_event, :string, default: nil
  attr :label, :string, default: "World map"
  attr :loading_label, :string, default: "Loading map"
  attr :class, :any, default: nil
  attr :rest, :global

  def world_map(assigns) do
    assigns =
      assigns
      |> assign(:points_json, encode(assigns.points))
      |> assign(:regions_json, encode(assigns.regions))
      |> assign(:arcs_json, encode(assigns.arcs))

    ~H"""
    <figure
      id={@id}
      class={["sr-map", @class]}
      phx-hook="SrWorldMap"
      data-points={@points_json}
      data-regions={@regions_json}
      data-arcs={@arcs_json}
      data-projection={@projection}
      data-topology-url={@topology_url}
      data-point-event={@point_event}
      data-region-event={@region_event}
      data-arc-event={@arc_event}
      {@rest}
    >
      <svg
        id={"#{@id}-svg"}
        class="sr-map-svg"
        viewBox="0 0 960 500"
        width="100%"
        role="img"
        aria-label={@label}
        focusable="false"
        phx-update="ignore"
      >
        <title>{@label}</title>
        <path class="sr-map-sphere" data-sr-layer="sphere" />
        <g class="sr-map-land" data-sr-layer="land"></g>
        <g class="sr-map-regions" data-sr-layer="regions"></g>
        <g class="sr-map-arcs" data-sr-layer="arcs"></g>
        <g class="sr-map-points" data-sr-layer="points"></g>
      </svg>
      <figcaption class="sr-map-status" data-sr-status>{@loading_label}</figcaption>
    </figure>
    """
  end

  defp encode(items) do
    items
    |> List.wrap()
    |> Enum.map(&jsonable/1)
    |> Jason.encode!()
  end

  # Structs (DateTime, Decimal, ...) are left to their Jason.Encoder.
  defp jsonable(%_{} = struct), do: struct

  defp jsonable(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), jsonable(v)} end)

  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> jsonable()
  defp jsonable(other), do: other
end
