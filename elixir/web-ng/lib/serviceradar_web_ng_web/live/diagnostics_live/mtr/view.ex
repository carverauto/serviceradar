defmodule ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.View do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.View.BulkPanel
  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.View.Modals
  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.View.Pagination
  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.View.Summary
  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.View.TraceTable

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="p-4 md:p-6 space-y-6">
        <div class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <h1 class="text-2xl font-bold">MTR Diagnostics</h1>
            <p class="sr-mtr-muted text-sm mt-1">Network path analysis traces from agents</p>
          </div>
          <div class="flex flex-wrap gap-2 sm:justify-end">
            <.ui_button navigate={~p"/diagnostics/mtr/compare"} size="sm" variant="outline">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-4 w-4"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M9 19V6l12-3v13M9 19c0 1.105-1.343 2-3 2s-3-.895-3-2 1.343-2 3-2 3 .895 3 2zm12-3c0 1.105-1.343 2-3 2s-3-.895-3-2 1.343-2 3-2 3 .895 3 2zM9 10l12-3"
                />
              </svg>
              Compare
            </.ui_button>
            <.ui_button type="button" phx-click="open_mtr_modal" size="sm" variant="primary">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-4 w-4"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M13 10V3L4 14h7v7l9-11h-7z"
                />
              </svg>
              Run MTR
            </.ui_button>
            <.ui_button type="button" phx-click="open_bulk_mtr_modal" size="sm" variant="soft">
              Bulk MTR
            </.ui_button>
          </div>
        </div>

        <Summary.render
          traces={@traces}
          trace_coverage={@trace_coverage}
          mtr_retention_status={@mtr_retention_status}
          timezone={@current_scope.user.timezone || "Etc/UTC"}
        />
        <BulkPanel.render
          bulk_jobs={@bulk_jobs}
          timezone={@current_scope.user.timezone || "Etc/UTC"}
        />
        <TraceTable.render
          traces={@traces}
          pending_jobs={@pending_jobs}
          filter_target={@filter_target}
          filter_agent={@filter_agent}
          timezone={@current_scope.user.timezone || "Etc/UTC"}
        />
        <div class="pt-1">
          <Pagination.render
            page={@current_page}
            limit={@limit}
            total_count={@total_count}
            query={Map.get(@srql || %{}, :query, "")}
            filter_target={@filter_target}
            filter_agent={@filter_agent}
          />
        </div>
        <Modals.mtr_modal
          show={@show_mtr_modal}
          mtr_error={@mtr_error}
          mtr_form={@mtr_form}
          mtr_agents={@mtr_agents}
        />
        <Modals.bulk_mtr_modal
          show={@show_bulk_mtr_modal}
          bulk_mtr_error={@bulk_mtr_error}
          bulk_mtr_form={@bulk_mtr_form}
          mtr_agents={@mtr_agents}
        />
      </div>
    </Layouts.app>
    """
  end
end
