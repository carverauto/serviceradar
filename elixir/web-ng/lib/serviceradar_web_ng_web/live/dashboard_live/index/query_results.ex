defmodule ServiceRadarWebNGWeb.DashboardLive.Index.QueryResults do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.SRQLComponents, only: [srql_results_table: 1]

  attr(:rows, :list, required: true)
  attr(:srql, :map, required: true)
  attr(:limit, :integer, required: true)
  attr(:current_page, :integer, required: true)
  attr(:timezone, :string, required: true)

  def render(assigns) do
    ~H"""
    <section id="dashboard-query-results" class="space-y-4">
      <div class="flex items-center justify-between">
        <h1 class="text-lg font-semibold">Query results</h1>
        <.link navigate={~p"/dashboard"} class="text-sm text-sr-brand">Operations dashboard</.link>
      </div>
      <p :if={@srql.error} id="dashboard-query-error" role="alert" class="text-sm text-red-700 dark:text-red-300">
        {@srql.error}
      </p>
      <.srql_results_table
        :if={is_nil(@srql.error)}
        id="dashboard-query-table"
        rows={@rows}
        timezone={@timezone}
        empty_message="No results for this query and time window."
      />
      <.ui_pagination
        :if={is_nil(@srql.error)}
        prev_cursor={Map.get(@srql.pagination, "prev_cursor")}
        next_cursor={Map.get(@srql.pagination, "next_cursor")}
        base_path="/dashboard"
        query={@srql.query}
        limit={@limit}
        result_count={length(@rows)}
        current_page={@current_page}
      />
    </section>
    """
  end
end
