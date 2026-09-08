defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Topology do
  @moduledoc false

  @behaviour ServiceRadarWebNGWeb.Dashboard.Plugin

  use Phoenix.LiveComponent

  # LiveComponent modules do not pull html_helpers from `use ServiceRadarWebNGWeb`.
  # Import shared primitives explicitly (codemod may introduce ui_button/ui_badge/etc).
  import ServiceRadarWebNGWeb.UIComponents

  @max_nodes 120
  @max_edges 240

  @impl true
  def id, do: "topology"

  @impl true
  def title, do: "Topology"

  @impl true
  def supports?(%{"results" => results}) when is_list(results) do
    Enum.any?(results, fn item ->
      case unwrap_payload(item) do
        %{"nodes" => nodes, "edges" => edges} when is_list(nodes) and is_list(edges) -> true
        %{"vertices" => nodes, "edges" => edges} when is_list(nodes) and is_list(edges) -> true
        _ -> false
      end
    end)
  end

  def supports?(_), do: false

  @impl true
  def build(%{"results" => results} = _srql_response) when is_list(results) do
    payloads =
      results
      |> Enum.map(&unwrap_payload/1)
      |> Enum.filter(&is_map/1)

    case merge_graph_payloads(payloads) do
      {:ok, graph} -> {:ok, graph}
      other -> other
    end
  end

  def build(_), do: {:error, :invalid_response}

  @impl true
  def update(%{panel_assigns: panel_assigns} = assigns, socket) do
    socket =
      socket
      |> assign(Map.delete(assigns, :panel_assigns))
      |> assign(panel_assigns || %{})
      |> assign_new(:selected_node_id, fn -> nil end)

    {:ok, socket}
  end

  @impl true
  def handle_event("select_node", %{"id" => node_id}, socket) do
    node_id = node_id |> to_string() |> String.trim()
    {:noreply, assign(socket, :selected_node_id, if(node_id == "", do: nil, else: node_id))}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected_node_id, nil)}
  end

  @impl true
  def render(assigns) do
    nodes = if is_list(assigns[:nodes]), do: assigns[:nodes], else: []
    edges = if is_list(assigns[:edges]), do: assigns[:edges], else: []
    selected_node_id = assigns[:selected_node_id]

    assigns =
      assigns
      |> assign(:nodes, nodes)
      |> assign(:edges, edges)
      |> assign(:selected_node_id, selected_node_id)
      |> assign_new(:total_node_count, fn -> length(nodes) end)
      |> assign_new(:truncated_node_count, fn -> 0 end)
      |> assign(:layout, layout(nodes))
      |> assign(:selected_node, find_node(nodes, selected_node_id))

    ~H"""
    <div id={"panel-#{@id}"}>
      <.ui_panel>
        <:header>
          <div class="min-w-0">
            <div class="text-sm font-semibold">Topology</div>
            <div class="text-xs text-sr-muted">
              Nodes: <span class="font-mono">{length(@nodes)}</span>
              <span :if={truncated_node_count(@truncated_node_count) > 0}>
                of <span class="font-mono">{@total_node_count}</span>
              </span>
              <.ui_badge
                :if={truncated_node_count(@truncated_node_count) > 0}
                size="xs"
                variant="warning"
                class="ml-1"
              >
                +{truncated_node_count(@truncated_node_count)} more
              </.ui_badge>
              <span class="opacity-60">·</span>
              Edges: <span class="font-mono">{length(@edges)}</span>
              <span :if={@selected_node_id} class="opacity-60">
                · Selected: <span class="font-mono">{@selected_node_id}</span>
              </span>
            </div>
          </div>

          <div class="shrink-0 flex items-center gap-2">
            <.ui_button
              :if={@selected_node_id}
              type="button"
              phx-click="clear_selection"
              phx-target={@myself}
              size="sm"
              variant="ghost"
            >
              Clear
            </.ui_button>
          </div>
        </:header>

        <div :if={@nodes == []} class="text-sm text-sr-muted">
          No graph results detected. Return a JSON object with <span class="font-mono">nodes</span>
          and <span class="font-mono">edges</span>.
        </div>

        <div :if={@nodes != []} class="grid grid-cols-1 lg:grid-cols-3 gap-4">
          <div class="lg:col-span-2 rounded-xl border border-sr-line bg-sr-surface overflow-hidden">
            <svg viewBox="0 0 1000 600" class="w-full h-[420px] bg-sr-surface">
              <defs>
                <marker
                  id="arrow"
                  markerWidth="10"
                  markerHeight="10"
                  refX="8"
                  refY="3"
                  orient="auto"
                >
                  <path d="M0,0 L0,6 L9,3 z" class="fill-sr-muted" />
                </marker>
              </defs>

              <%= for edge <- @edges do %>
                <% src = Map.get(@layout, edge.source) %>
                <% dst = Map.get(@layout, edge.target) %>
                <% selected? =
                  @selected_node_id &&
                    (edge.source == @selected_node_id || edge.target == @selected_node_id) %>

                <line
                  :if={src && dst}
                  x1={src.x}
                  y1={src.y}
                  x2={dst.x}
                  y2={dst.y}
                  stroke-width={if selected?, do: 2.5, else: 1.5}
                  class={
                    if selected?,
                      do: "stroke-sr-brand/80",
                      else: "stroke-sr-muted/25"
                  }
                  marker-end="url(#arrow)"
                />
              <% end %>

              <%= for node <- @nodes do %>
                <% pos = Map.get(@layout, node.id) %>
                <% selected? = @selected_node_id == node.id %>

                <g
                  :if={pos}
                  class="cursor-pointer"
                  phx-click="select_node"
                  phx-target={@myself}
                  phx-value-id={node.id}
                >
                  <circle
                    cx={pos.x}
                    cy={pos.y}
                    r={if selected?, do: 14, else: 11}
                    class={
                      if selected?,
                        do: "fill-sr-brand stroke-sr-brand/40",
                        else: "fill-sr-subtle stroke-sr-line"
                    }
                    stroke-width="2"
                  />
                  <text
                    x={pos.x + 16}
                    y={pos.y + 4}
                    class={
                      if selected?,
                        do: "fill-sr-ink text-xs font-semibold",
                        else: "fill-sr-ink/80 text-xs"
                    }
                  >
                    {node.label}
                  </text>
                </g>
              <% end %>
            </svg>
          </div>

          <div class="rounded-xl border border-sr-line bg-sr-surface p-4">
            <div class="text-xs font-semibold mb-2">Selected Node</div>

            <div :if={is_nil(@selected_node)} class="text-sm text-sr-muted">
              Click a node to inspect details.
            </div>

            <div :if={not is_nil(@selected_node)} class="flex flex-col gap-3">
              <div class="text-sm font-semibold truncate">{@selected_node.label}</div>
              <div class="text-xs text-sr-muted">
                <span class="font-mono">{@selected_node.id}</span>
              </div>

              <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3 overflow-x-auto">
                <pre class="text-xs leading-relaxed"><%= Jason.encode!(@selected_node.raw, pretty: true) %></pre>
              </div>
            </div>
          </div>
        </div>
      </.ui_panel>
    </div>
    """
  end

  defp unwrap_payload(%{"result" => value}), do: value
  defp unwrap_payload(value), do: value

  defp merge_graph_payloads(payloads) when is_list(payloads) do
    {nodes, edges} =
      Enum.reduce(payloads, {[], []}, fn payload, {nodes_acc, edges_acc} ->
        {nodes, edges} = graph_parts(payload)
        {nodes_acc ++ nodes, edges_acc ++ edges}
      end)

    normalized_nodes =
      nodes
      |> Enum.filter(&is_map/1)
      |> Enum.map(&normalize_node/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)

    total_node_count = length(normalized_nodes)
    nodes = truncate_nodes(normalized_nodes)
    truncated_node_count = max(total_node_count - length(nodes), 0)

    node_ids = MapSet.new(Enum.map(nodes, & &1.id))

    edges =
      edges
      |> Enum.filter(&is_map/1)
      |> Enum.map(&normalize_edge/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn e ->
        MapSet.member?(node_ids, e.source) and MapSet.member?(node_ids, e.target)
      end)
      |> Enum.uniq_by(fn e -> {e.source, e.target, e.label} end)
      |> Enum.take(@max_edges)

    {:ok,
     %{
       nodes: nodes,
       edges: edges,
       total_node_count: total_node_count,
       truncated_node_count: truncated_node_count
     }}
  end

  defp merge_graph_payloads(_), do: {:error, :invalid_payloads}

  defp graph_parts(%{"nodes" => nodes, "edges" => edges}) when is_list(nodes) and is_list(edges), do: {nodes, edges}

  defp graph_parts(%{"vertices" => nodes, "edges" => edges}) when is_list(nodes) and is_list(edges), do: {nodes, edges}

  defp graph_parts(_), do: {[], []}

  defp truncate_nodes(nodes) when length(nodes) > @max_nodes do
    visible_count = max(@max_nodes - 1, 0)
    hidden_count = length(nodes) - visible_count

    Enum.take(nodes, visible_count) ++
      [
        %{
          id: "__truncated_nodes__",
          label: "+#{hidden_count} more",
          raw: %{"truncated_count" => hidden_count, "truncated" => true}
        }
      ]
  end

  defp truncate_nodes(nodes), do: nodes

  defp normalize_node(%{} = raw) do
    id =
      first_string(raw, ["id", "uid", "device_id", "gateway_id", "agent_id", "name"]) ||
        fallback_id(raw)

    label = first_string(raw, ["label", "hostname", "name"]) || id

    if is_binary(id) and id != "" do
      %{id: id, label: String.slice(label, 0, 80), raw: raw}
    end
  end

  defp normalize_edge(%{} = raw) do
    source = first_string(raw, ["source", "from", "src", "start", "start_id", "from_id"])
    target = first_string(raw, ["target", "to", "dst", "end", "end_id", "to_id"])
    label = first_string(raw, ["label", "type", "kind", "name"]) || ""

    if is_binary(source) and is_binary(target) and source != "" and target != "" do
      %{source: source, target: target, label: String.slice(label, 0, 60), raw: raw}
    end
  end

  defp layout(nodes) when is_list(nodes) do
    nodes =
      nodes
      |> Enum.filter(&is_map/1)
      |> Enum.take(@max_nodes)

    count = length(nodes)

    positions =
      cond do
        count == 0 ->
          []

        count <= 24 ->
          circle_positions(count, 500, 300, 220)

        true ->
          grid_positions(count, 120, 120, 980, 560)
      end

    nodes
    |> Enum.zip(positions)
    |> Map.new(fn {%{id: id}, {x, y}} -> {id, %{x: x, y: y}} end)
  end

  defp layout(_), do: %{}

  defp circle_positions(count, cx, cy, r) do
    Enum.map(0..(count - 1), fn idx ->
      theta = 2.0 * :math.pi() * idx / count
      x = cx + r * :math.cos(theta)
      y = cy + r * :math.sin(theta)
      {round(x), round(y)}
    end)
  end

  defp grid_positions(count, x0, y0, width, height) do
    cols = max(1, count |> :math.sqrt() |> Float.ceil() |> trunc())
    rows = max(1, (count / cols) |> Float.ceil() |> trunc())
    dx = max(1, div(width - x0, max(cols - 1, 1)))
    dy = max(1, div(height - y0, max(rows - 1, 1)))

    Enum.map(0..(count - 1), fn idx ->
      col = rem(idx, cols)
      row = div(idx, cols)
      {x0 + col * dx, y0 + row * dy}
    end)
  end

  defp find_node(_nodes, nil), do: nil

  defp find_node(nodes, id) when is_list(nodes) and is_binary(id) do
    Enum.find(nodes, fn
      %{id: ^id} -> true
      _ -> false
    end)
  end

  defp find_node(_, _), do: nil

  defp first_string(map, keys) do
    Enum.reduce_while(keys, nil, fn key, _acc ->
      case Map.get(map, key) do
        nil ->
          {:cont, nil}

        value when is_binary(value) and value != "" ->
          {:halt, value}

        value when is_integer(value) ->
          {:halt, Integer.to_string(value)}

        value when is_atom(value) ->
          {:halt, Atom.to_string(value)}

        _ ->
          {:cont, nil}
      end
    end)
  end

  defp fallback_id(raw) do
    digest =
      raw
      |> canonical_value()
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "node:#{digest}"
  rescue
    _ -> ""
  end

  defp canonical_value(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> [to_string(key), canonical_value(value)] end)
    |> Enum.sort_by(&List.first/1)
  end

  defp canonical_value(list) when is_list(list), do: Enum.map(list, &canonical_value/1)
  defp canonical_value(value) when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp canonical_value(value) when is_atom(value), do: Atom.to_string(value)
  defp canonical_value(value), do: inspect(value)

  defp truncated_node_count(value) when is_integer(value), do: max(value, 0)
  defp truncated_node_count(_), do: 0
end
