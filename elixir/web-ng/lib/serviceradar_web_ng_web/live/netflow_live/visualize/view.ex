defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.View do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.View.ChartPanel
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.View.Controls
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.View.FlowModal
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.View.FlowsPanel

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="sr-observability-page mx-auto max-w-7xl space-y-4 p-6 font-sans">
        <.observability_chrome active_pane="netflows" />

        <div class="flex flex-col lg:flex-row gap-4 items-start">
          <Controls.render visualize={assigns} />

          <section class="w-full min-w-0 flex-1 flex flex-col gap-4">
            <ChartPanel.render visualize={assigns} />
            <FlowsPanel.render visualize={assigns} />
            <FlowModal.render
              :if={is_map(@selected_flow)}
              flow={@selected_flow}
              rdns_map={@rdns_map}
              context={@selected_flow_context}
              arin_lookup={@arin_lookup}
            />
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
