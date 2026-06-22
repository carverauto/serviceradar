defmodule ServiceRadarWebNGWeb.NetflowLive.Dashboard.View do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.NetflowLive.Dashboard.View.Capacity
  alias ServiceRadarWebNGWeb.NetflowLive.Dashboard.View.Controls
  alias ServiceRadarWebNGWeb.NetflowLive.Dashboard.View.Overview
  alias ServiceRadarWebNGWeb.NetflowLive.Dashboard.View.TopLists
  alias ServiceRadarWebNGWeb.NetflowLive.Dashboard.View.Traffic

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="px-4 py-4 space-y-4">
        <Controls.render dashboard={assigns} />
        <Overview.render dashboard={assigns} />
        <Traffic.render dashboard={assigns} />
        <TopLists.render dashboard={assigns} />
        <Capacity.render dashboard={assigns} />
      </div>
    </Layouts.app>
    """
  end
end
