defmodule ServiceRadarWebNGWeb.ServiceLive.Index.View do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.ServiceLive.Index.CardGrid
  alias ServiceRadarWebNGWeb.ServiceLive.Index.Summary

  def render(assigns) do
    query = Map.get(assigns.srql, :query, "")

    has_filter =
      is_binary(query) and
        Regex.match?(~r/(?:^|\s)(?:service_name|service_type|type|service):/, query)

    assigns =
      assigns
      |> assign(:has_filter, has_filter)
      |> assign(:timezone, user_timezone(assigns[:current_scope]))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6">
        <div class="space-y-4">
          <Summary.render summary={@summary} has_filter={@has_filter} timezone={@timezone} />

          <.ui_panel>
            <:header>
              <div class="min-w-0">
                <div class="text-sm font-semibold">Active Service Checks</div>
                <div class="text-xs text-sr-muted">
                  Latest plugin check per service (sorted with failures first).
                </div>
              </div>
            </:header>

            <CardGrid.render cards={@streams.service_cards} timezone={@timezone} />
          </.ui_panel>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp user_timezone(%{user: %{timezone: timezone}}) when is_binary(timezone) and timezone != "", do: timezone

  defp user_timezone(_current_scope), do: "Etc/UTC"
end
