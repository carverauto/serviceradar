defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.View.Controls.Dimensions do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.NetflowLive.Visualize.QueryState,
    only: [dims_from_state: 1, sanitize_sankey_dims: 1]

  attr(:netflow_viz_state, :map, required: true)
  attr(:sankey_src_dims, :list, required: true)
  attr(:sankey_mid_dims, :list, required: true)
  attr(:sankey_dst_dims, :list, required: true)
  attr(:nf_dims_ordered, :list, required: true)

  def render(assigns) do
    ~H"""
    <div class="col-span-2">
      <div class="text-xs font-semibold text-sr-muted mb-1">Dimensions</div>
      <form phx-change="nf_state_change" class="space-y-2">
        <% graph = Map.get(@netflow_viz_state, "graph", "stacked") %>
        <%= if graph == "sankey" do %>
          <% dims = @netflow_viz_state |> dims_from_state() |> sanitize_sankey_dims() %>
          <div class="grid grid-cols-3 gap-2">
            <.sankey_select label="Source" dims={@sankey_src_dims} selected={Enum.at(dims, 0)} />
            <.sankey_select label="Middle" dims={@sankey_mid_dims} selected={Enum.at(dims, 1)} />
            <.sankey_select label="Destination" dims={@sankey_dst_dims} selected={Enum.at(dims, 2)} />
          </div>
        <% else %>
          <% primary = Map.get(@netflow_viz_state, "dims", []) |> List.wrap() |> List.first() %>
          <select
            name="state[dims][]"
            class={ui_field_class(size: "sm", mono: true, class: "w-full text-xs")}
          >
            <%= for {label, value} <- @nf_dims_ordered do %>
              <option value={value} selected={primary == value}>{label}</option>
            <% end %>
          </select>
        <% end %>

        <div class="text-[11px] text-sr-muted">
          Time-series charts group by the selected dimension; Sankey uses source -> middle -> destination.
          Exporter/interface dimensions may appear as <span class="font-mono">Unknown</span>
          until the NetFlow cache refresh job populates metadata.
        </div>
      </form>

      <.dimension_order graph={graph} dims={Map.get(@netflow_viz_state, "dims", [])} />
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:dims, :list, required: true)
  attr(:selected, :string, default: nil)

  def sankey_select(assigns) do
    ~H"""
    <div class="space-y-1">
      <div class="text-[11px] text-sr-muted">{@label}</div>
      <select
        name="state[dims][]"
        class={ui_field_class(size: "sm", mono: true, class: "w-full text-xs")}
      >
        <%= for {label, value} <- @dims do %>
          <option value={value} selected={@selected == value}>{label}</option>
        <% end %>
      </select>
    </div>
    """
  end

  attr(:graph, :string, required: true)
  attr(:dims, :list, required: true)

  def dimension_order(assigns) do
    ~H"""
    <div :if={@graph != "sankey" and length(@dims) > 1} class="mt-2 space-y-1">
      <div class="text-[11px] text-sr-muted">Order</div>
      <div class="space-y-1">
        <%= for dim <- @dims do %>
          <div class="flex items-center gap-2">
            <.ui_badge size="sm" variant="ghost" class="font-mono text-[11px]">{dim}</.ui_badge>
            <.ui_button
              type="button"
              phx-click="nf_dim_move"
              phx-value-dim={dim}
              phx-value-dir="up"
              size="xs"
              variant="ghost"
            >
              Up
            </.ui_button>
            <.ui_button
              type="button"
              phx-click="nf_dim_move"
              phx-value-dim={dim}
              phx-value-dir="down"
              size="xs"
              variant="ghost"
            >
              Down
            </.ui_button>
            <.ui_button
              type="button"
              phx-click="nf_dim_remove"
              phx-value-dim={dim}
              size="xs"
              variant="ghost"
              class="text-error"
            >
              Remove
            </.ui_button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
