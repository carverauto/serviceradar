defmodule ServiceRadarWebNGWeb.NetflowLive.Dashboard.View do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.NetflowLive.Dashboard.View.Capacity
  alias ServiceRadarWebNGWeb.NetflowLive.Dashboard.View.Controls
  alias ServiceRadarWebNGWeb.NetflowLive.Dashboard.View.Overview
  alias ServiceRadarWebNGWeb.NetflowLive.Dashboard.View.TopLists
  alias ServiceRadarWebNGWeb.NetflowLive.Dashboard.View.Traffic

  def render(assigns) do
    assigns = assign(assigns, :timezone, user_timezone(assigns[:current_scope]))

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

  defp user_timezone(%{user: %{timezone: timezone}}) when is_binary(timezone) and timezone != "", do: timezone

  defp user_timezone(_current_scope), do: "Etc/UTC"
end
