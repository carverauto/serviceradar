defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.View.Controls.BgpFilterPanel do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.View.BgpFilters

  attr(:query, :string, required: true)

  def render(assigns) do
    ~H"""
    <div class="col-span-full mt-4 pt-4 border-t border-sr-line">
      <details class="sr-ui-collapse sr-ui-collapse-arrow bg-sr-subtle/30 rounded-lg">
        <summary class="sr-ui-collapse-title text-xs font-semibold text-sr-muted min-h-0 py-2 px-3">
          BGP Routing Filters
        </summary>
        <div class="sr-ui-collapse-content px-3 pb-3">
          <BgpFilters.render query={@query} />
        </div>
      </details>
    </div>
    """
  end
end
