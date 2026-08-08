defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.View.Controls do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.View.Controls.BgpFilterPanel
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.View.Controls.Dimensions

  attr(:visualize, :map, required: true)

  def render(%{visualize: visualize} = assigns) do
    assigns = Map.merge(assigns, visualize)

    ~H"""
    <aside class="w-full lg:w-80 shrink-0">
      <div class="sr-ui-card bg-sr-surface border border-sr-line">
        <div class="sr-ui-card-body gap-3">
          <div class="min-w-0">
            <div class="text-base font-semibold">Network Flows</div>
            <div class="text-xs text-sr-muted">
              SRQL-driven analytics (preview). Charts and dimensions will expand in follow-up changes.
            </div>
          </div>

          <div :if={@netflow_viz_state_error} class={ui_alert_class("warning")}>
            <div class="text-xs">
              Invalid `nf` state in URL: <span class="font-mono">{inspect(@netflow_viz_state_error)}</span>.
              Using defaults.
            </div>
          </div>

          <div class="grid grid-cols-2 gap-2">
            <div class="col-span-2">
              <div class="text-xs font-semibold text-sr-muted mb-1">Graph</div>
              <form phx-change="nf_state_change">
                <select
                  name="state[graph]"
                  class={ui_field_class(size: "sm", mono: true, class: "w-full text-xs")}
                >
                  <%= for {label, value} <- [{"Stacked", "stacked"}, {"100% Stacked", "stacked100"}, {"Lines", "lines"}, {"Grid", "grid"}, {"Sankey", "sankey"}] do %>
                    <option
                      value={value}
                      selected={Map.get(@netflow_viz_state, "graph") == value}
                    >
                      {label}
                    </option>
                  <% end %>
                </select>
              </form>
            </div>

            <Dimensions.render
              netflow_viz_state={@netflow_viz_state}
              sankey_src_dims={@sankey_src_dims}
              sankey_mid_dims={@sankey_mid_dims}
              sankey_dst_dims={@sankey_dst_dims}
              nf_dims_ordered={@nf_dims_ordered}
            />

            <div class="col-span-2">
              <div class="text-xs font-semibold text-sr-muted mb-1">Units</div>
              <form phx-change="nf_state_change">
                <select
                  name="state[units]"
                  class={ui_field_class(size: "sm", mono: true, class: "w-full text-xs")}
                >
                  <%= for {label, value} <- [{"Bytes/sec (Bps)", "Bps"}, {"Bits/sec (bps)", "bps"}, {"Packets/sec (pps)", "pps"}] do %>
                    <option
                      value={value}
                      selected={Map.get(@netflow_viz_state, "units") == value}
                    >
                      {label}
                    </option>
                  <% end %>
                </select>
              </form>
            </div>

            <div class="col-span-2">
              <div class="text-xs font-semibold text-sr-muted mb-1">Top-N</div>
              <form phx-change="nf_state_change" class="grid grid-cols-2 gap-2">
                <input
                  type="number"
                  min="1"
                  max="50"
                  name="state[limit]"
                  value={Map.get(@netflow_viz_state, "limit")}
                  class={ui_field_class(size: "sm", mono: true, class: "w-full text-xs")}
                />

                <select
                  name="state[limit_type]"
                  class={ui_field_class(size: "sm", mono: true, class: "w-full text-xs")}
                >
                  <%= for {label, value} <- [{"avg", "avg"}, {"max", "max"}, {"last", "last"}] do %>
                    <option
                      value={value}
                      selected={Map.get(@netflow_viz_state, "limit_type") == value}
                    >
                      {label}
                    </option>
                  <% end %>
                </select>
              </form>
            </div>

            <div class="col-span-2">
              <div class="text-xs font-semibold text-sr-muted mb-1">Prefix tag</div>
              <form phx-submit="nf_prefix_tag_filter" class="flex gap-2">
                <input
                  type="text"
                  name="tag"
                  value={
                    ServiceRadarWebNGWeb.Netflow.PrefixTagQuery.tag_from_query(
                      (Map.get(assigns, :srql) || %{})[:query] ||
                        Map.get(assigns, :query) ||
                        ""
                    ) || ""
                  }
                  placeholder="site:austin"
                  class={ui_field_class(size: "sm", mono: true, class: "w-full text-xs")}
                  autocomplete="off"
                />
                <.ui_button type="submit" size="sm" variant="ghost">Filter</.ui_button>
              </form>
              <div class="mt-1 text-[11px] text-sr-muted">
                Adds <span class="font-mono">tag:…</span> to the SRQL query (either side).
              </div>
            </div>

            <div class="col-span-2">
              <div class="text-xs font-semibold text-sr-muted mb-1">Truncate</div>
              <form phx-change="nf_state_change" class="grid grid-cols-2 gap-2">
                <div class="space-y-1">
                  <div class="text-[11px] text-sr-muted">IPv4 prefix bits</div>
                  <input
                    type="number"
                    min="0"
                    max="32"
                    name="state[truncate_v4]"
                    value={Map.get(@netflow_viz_state, "truncate_v4")}
                    class={ui_field_class(size: "sm", mono: true, class: "w-full text-xs")}
                  />
                </div>

                <div class="space-y-1">
                  <div class="text-[11px] text-sr-muted">IPv6 prefix bits</div>
                  <input
                    type="number"
                    min="0"
                    max="128"
                    name="state[truncate_v6]"
                    value={Map.get(@netflow_viz_state, "truncate_v6")}
                    class={ui_field_class(size: "sm", mono: true, class: "w-full text-xs")}
                  />
                </div>
              </form>
            </div>

            <div class="col-span-2">
              <div class="text-xs font-semibold text-sr-muted mb-1">Time</div>
              <form phx-change="nf_state_change">
                <select
                  name="state[time]"
                  class={ui_field_class(size: "sm", mono: true, class: "w-full text-xs")}
                >
                  <%= for value <- ["last_1h", "last_6h", "last_12h", "last_24h", "last_7d", "last_30d"] do %>
                    <option
                      value={value}
                      selected={Map.get(@netflow_viz_state, "time") == value}
                    >
                      {value}
                    </option>
                  <% end %>
                </select>
              </form>
            </div>

            <div class="col-span-2">
              <div class="text-xs font-semibold text-sr-muted mb-1">Overlays</div>
              <form phx-change="nf_state_change" class="space-y-2">
                <input type="hidden" name="state[bidirectional]" value="false" />
                <label class="flex items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    class={ui_checkbox_class()}
                    name="state[bidirectional]"
                    value="true"
                    checked={Map.get(@netflow_viz_state, "bidirectional") == true}
                  />
                  <span class="text-xs">Bidirectional (reverse)</span>
                </label>

                <input type="hidden" name="state[previous_period]" value="false" />
                <label class="flex items-center gap-2 cursor-pointer">
                  <input
                    type="checkbox"
                    class={ui_checkbox_class()}
                    name="state[previous_period]"
                    value="true"
                    checked={Map.get(@netflow_viz_state, "previous_period") == true}
                  />
                  <span class="text-xs">Previous period</span>
                </label>

                <div class="text-[11px] text-sr-muted">
                  Overlays are currently supported on <span class="font-mono">lines</span>
                  and <span class="font-mono">stacked</span>
                  and <span class="font-mono">stacked100</span>.
                </div>
              </form>
            </div>

            <BgpFilterPanel.render query={Map.get(@srql, :query) || ""} />
          </div>

          <div class="flex items-center justify-between">
            <.ui_button type="button" phx-click="nf_reset" size="sm" variant="ghost">
              Reset view state
            </.ui_button>

            <div class="text-[11px] text-sr-muted">
              URL param: <span class="font-mono">nf</span>
            </div>
          </div>
        </div>
      </div>
    </aside>
    """
  end
end
