defmodule ServiceRadarWebNGWeb.ServiceLive.Show.View do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.PluginResults

  alias ServiceRadarWebNGWeb.ServiceLive.Service
  alias ServiceRadarWebNGWeb.ServiceLive.Show.HistoryTable

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-5xl p-6">
        <div class="space-y-4">
          <.ui_panel>
            <:header>
              <div class="flex items-start justify-between gap-3">
                <div>
                  <div class="text-sm font-semibold">Service Check Details</div>
                  <div class="text-xs text-base-content/70">
                    <span :if={@service}>
                      {Service.name(@service) || "Service"}
                    </span>
                    <span :if={!@service}>No matching service check found.</span>
                  </div>
                </div>
                <.ui_button navigate={~p"/services"} size="xs" variant="ghost">
                  Back to services
                </.ui_button>
              </div>
            </:header>

            <div :if={!@service} class="text-sm text-base-content/60">
              We could not find a matching service check for the requested time.
            </div>

            <div :if={@service} class="space-y-4">
              <div class="flex flex-wrap gap-4 text-xs text-base-content/70">
                <div>
                  <span class="font-semibold">Status:</span> {format_status(
                    Service.status(@service, @details)
                  )}
                </div>
                <div>
                  <span class="font-semibold">Type:</span> {Service.type(@service) || "—"}
                </div>
                <div>
                  <span class="font-semibold">Service:</span> {Service.name(@service) || "—"}
                </div>
                <div>
                  <span class="font-semibold">Gateway:</span> {Map.get(@service, "gateway_id") || "—"}
                </div>
                <div>
                  <span class="font-semibold">Agent:</span> {Map.get(@service, "agent_id") || "—"}
                </div>
                <div>
                  <span class="font-semibold">Partition:</span> {Map.get(@service, "partition") || "—"}
                </div>
                <div>
                  <span class="font-semibold">Observed:</span> {Map.get(@service, "timestamp") || "—"}
                </div>
              </div>

              <div class="text-sm">{Service.summary(@service, @details) || "—"}</div>

              <div :if={@schema_version} class="text-[11px] text-base-content/50">
                UI schema version {@schema_version}
              </div>

              <.plugin_results display={@display} />
            </div>
          </.ui_panel>

          <.ui_panel>
            <:header>
              <div class="text-sm font-semibold">Service Check History</div>
            </:header>

            <HistoryTable.render
              services={@history}
              page={@history_page}
              per_page={@history_per_page}
            />
          </.ui_panel>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp format_status(status) do
    status
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "—"
      value -> value
    end
  end
end
