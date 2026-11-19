defmodule ServiceRadarWebNGWeb.ServiceLive.Checks.Components do
  @moduledoc """
  HEEx components for the `/services/checks` Check Results Explorer:
  KPI status summary cards, quick filter pills, expandable SRQL results table,
  and `stats:` rollup views.
  """

  use ServiceRadarWebNGWeb, :html

  @page_path "/services/checks"
  @stats_group_order [
    "check_slug",
    "check",
    "check_name",
    "check_id",
    "status",
    "verdict",
    "state",
    "target_kind",
    "target_key",
    "device_uid"
  ]

  attr :summary, :map, required: true
  attr :active_query, :string, required: true

  def kpi_summary_cards(assigns) do
    cards = [
      %{
        key: "healthy",
        label: "Healthy",
        count: Map.get(assigns.summary, "healthy", 0),
        query: "in:declarative_check_results status:healthy limit:50",
        accent: "text-emerald-400",
        dot: "bg-emerald-400"
      },
      %{
        key: "degraded",
        label: "Degraded",
        count: Map.get(assigns.summary, "degraded", 0),
        query: "in:declarative_check_results status:degraded limit:50",
        accent: "text-amber-400",
        dot: "bg-amber-400"
      },
      %{
        key: "down",
        label: "Down",
        count: Map.get(assigns.summary, "down", 0),
        query: "in:declarative_check_results status:down limit:50",
        accent: "text-rose-400",
        dot: "bg-rose-400"
      },
      %{
        key: "unknown",
        label: "Unknown",
        count: Map.get(assigns.summary, "unknown", 0),
        query: "in:declarative_check_results status:unknown limit:50",
        accent: "text-sr-muted",
        dot: "bg-sr-muted"
      }
    ]

    assigns = assign(assigns, :cards, cards)

    ~H"""
    <section
      id="check-results-kpi-cards"
      aria-label="Check status summary"
      class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4"
    >
      <.link
        :for={card <- @cards}
        id={"check-results-kpi-#{card.key}"}
        patch={query_path(card.query)}
        class={[
          "rounded-lg border bg-sr-surface p-4 transition-colors hover:border-sr-line-hover",
          String.contains?(@active_query, "status:#{card.key}") && "border-sr-brand",
          !String.contains?(@active_query, "status:#{card.key}") && "border-sr-line"
        ]}
      >
        <div class="flex items-center justify-between gap-2">
          <span class="text-xs font-medium text-sr-muted">{card.label}</span>
          <span class={["size-2 rounded-full", card.dot]}></span>
        </div>
        <div class={["mt-2 text-2xl font-semibold tabular-nums", card.accent]}>
          {card.count}
        </div>
      </.link>
    </section>
    """
  end

  attr :active_filter, :string, required: true
  attr :active_query, :string, required: true
  attr :default_query, :string, required: true

  def quick_filter_bar(assigns) do
    pills = [
      %{id: "all", label: "All", query: assigns.default_query},
      %{
        id: "failing",
        label: "Failing",
        query: "in:declarative_check_results status:(down,degraded) limit:50"
      },
      %{
        id: "healthy",
        label: "Healthy",
        query: "in:declarative_check_results status:healthy limit:50"
      },
      %{
        id: "stats",
        label: "Stats by Status",
        query: "in:declarative_check_results stats:count() as total by status"
      }
    ]

    assigns = assign(assigns, :pills, pills)

    ~H"""
    <div
      id="check-results-filter-pills"
      class="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-sr-line bg-sr-surface p-3"
    >
      <div class="flex flex-wrap items-center gap-2">
        <.link
          :for={pill <- @pills}
          id={"check-results-pill-#{pill.id}"}
          patch={query_path(pill.query)}
          class={[
            "rounded-full border px-3 py-1 text-xs font-medium transition-colors",
            @active_filter == pill.id &&
              "border-sr-brand bg-sr-brand/15 text-sr-ink",
            @active_filter != pill.id &&
              "border-sr-line bg-sr-control text-sr-muted hover:text-sr-ink hover:bg-sr-subtle"
          ]}
        >
          {pill.label}
        </.link>
      </div>

      <code
        id="check-results-active-query"
        class="max-w-full truncate font-mono text-xs text-sr-muted"
      >
        {@active_query}
      </code>
    </div>
    """
  end

  attr :results, :list, required: true
  attr :expanded_rows, :any, required: true
  attr :timezone, :string, default: "Etc/UTC"

  def results_table(assigns) do
    ~H"""
    <div class="sr-ui-table-shell overflow-x-auto">
      <table
        id="check-results-table"
        class={ui_table_class(size: "sm", zebra: false, class: "w-full")}
      >
        <thead>
          <tr>
            <th class="w-8 bg-sr-subtle/60"></th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
              Check
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
              Target
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
              Kind
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
              Verdict
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
              Status
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
              Evaluated
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60">
              Changed
            </th>
          </tr>
        </thead>
        <tbody>
          <%= for {row, idx} <- Enum.with_index(@results) do %>
            <% row_key = row_identity(row, idx) %>
            <% expanded? = MapSet.member?(@expanded_rows, row_key) %>
            <% slug = row_field(row, "check_slug") || row_field(row, "slug") %>
            <% check_name = row_field(row, "check_name") %>
            <tr
              id={"check-result-row-#{idx}"}
              class="border-t border-sr-line/60 hover:bg-sr-subtle/40 transition-colors"
            >
              <td class="whitespace-nowrap text-xs">
                <button
                  id={"toggle-result-details-#{idx}"}
                  type="button"
                  phx-click="toggle_row_details"
                  phx-value-row_key={row_key}
                  aria-expanded={to_string(expanded?)}
                  aria-label="Toggle check result output details"
                  class="inline-flex size-6 items-center justify-center rounded border border-sr-line text-sr-muted hover:text-sr-ink hover:bg-sr-subtle"
                >
                  <.icon
                    name={if(expanded?, do: "hero-chevron-down", else: "hero-chevron-right")}
                    class="size-3.5"
                  />
                </button>
              </td>
              <td class="whitespace-nowrap text-xs">
                <%= if is_binary(slug) and slug != "" do %>
                  <.link
                    navigate={~p"/settings/declarative-checks/#{slug}"}
                    class="font-mono font-medium text-sr-ink hover:underline"
                  >
                    {slug}
                  </.link>
                  <div
                    :if={is_binary(check_name) and check_name != "" and check_name != slug}
                    class="text-[11px] text-sr-muted"
                  >
                    {check_name}
                  </div>
                <% else %>
                  <span class="text-sr-muted">-</span>
                <% end %>
              </td>
              <td class="whitespace-nowrap text-xs font-mono text-sr-ink">
                {format_cell(row_field(row, "target_key"))}
              </td>
              <td class="whitespace-nowrap text-xs">
                <span class="inline-flex items-center rounded-sr-control border border-sr-line bg-sr-subtle px-2 py-0.5 text-[11px] text-sr-muted">
                  {format_cell(row_field(row, "target_kind"))}
                </span>
              </td>
              <td class="whitespace-nowrap text-xs font-mono text-sr-ink">
                {format_cell(row_field(row, "verdict"))}
              </td>
              <td class="whitespace-nowrap text-xs">
                <.result_status_badge status={row_field(row, "status")} />
              </td>
              <td class="whitespace-nowrap text-xs font-mono text-sr-muted">
                <.user_time
                  id={"check-result-evaluated-#{idx}"}
                  value={row_field(row, "evaluated_at")}
                  timezone={@timezone}
                  fallback="-"
                />
              </td>
              <td class="whitespace-nowrap text-xs font-mono text-sr-muted">
                <.user_time
                  id={"check-result-changed-#{idx}"}
                  value={row_field(row, "changed_at")}
                  timezone={@timezone}
                  fallback="-"
                />
              </td>
            </tr>

            <tr :if={expanded?} id={"check-result-details-#{idx}"} class="bg-sr-subtle/30">
              <td colspan="8" class="p-4">
                <.row_details_panel row={row} />
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :row, :map, required: true

  defp row_details_panel(assigns) do
    summary = row_field(assigns.row, "summary")
    device_uid = row_field(assigns.row, "device_uid")
    service_target_id = row_field(assigns.row, "service_target_id")
    state = row_field(assigns.row, "state")
    snapshots = row_field(assigns.row, "node_snapshots")

    assigns =
      assigns
      |> assign(:summary, summary)
      |> assign(:device_uid, device_uid)
      |> assign(:service_target_id, service_target_id)
      |> assign(:state, state)
      |> assign(:snapshots_json, format_snapshots(snapshots))

    ~H"""
    <div class="space-y-3 text-xs">
      <div class="flex flex-wrap items-center gap-4 text-sr-muted">
        <span :if={@state not in [nil, ""]}>
          Check State: <strong class="text-sr-ink">{@state}</strong>
        </span>
        <span :if={is_binary(@device_uid) and @device_uid != ""}>
          Device:
          <.link
            navigate={~p"/devices/#{@device_uid}"}
            class="font-mono text-sr-ink hover:underline"
          >
            {@device_uid}
          </.link>
        </span>
        <span :if={is_binary(@service_target_id) and @service_target_id != ""}>
          Service Target: <code class="font-mono text-sr-ink">{@service_target_id}</code>
        </span>
      </div>

      <div>
        <div class="font-semibold text-sr-ink">Output / Message</div>
        <p class="mt-1 whitespace-pre-wrap rounded border border-sr-line bg-sr-surface p-2.5 text-sr-ink">
          {if @summary in [nil, ""], do: "No output message recorded.", else: @summary}
        </p>
      </div>

      <div :if={@snapshots_json}>
        <div class="font-semibold text-sr-ink">Node Snapshots (Redacted)</div>
        <pre
          phx-no-curly-interpolation
          class="mt-1 max-h-60 overflow-auto rounded border border-sr-line bg-sr-surface p-2.5 font-mono text-[11px] text-sr-ink"
        ><%= @snapshots_json %></pre>
      </div>
    </div>
    """
  end

  attr :results, :list, required: true

  def stats_view(assigns) do
    columns = stats_columns(assigns.results)
    {group_cols, metric_cols} = split_stats_columns(columns, assigns.results)
    primary_metric = List.first(metric_cols) || List.last(columns)
    cards = Enum.take(assigns.results, 8)

    assigns =
      assigns
      |> assign(:columns, columns)
      |> assign(:group_cols, group_cols)
      |> assign(:primary_metric, primary_metric)
      |> assign(:cards, cards)

    ~H"""
    <div class="space-y-4">
      <div
        id="check-results-stats-cards"
        class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4"
      >
        <%= for {row, idx} <- Enum.with_index(@cards) do %>
          <div
            id={"check-results-stats-card-#{idx}"}
            class="rounded-lg border border-sr-line bg-sr-surface p-4 space-y-2"
          >
            <div class="flex flex-wrap items-center justify-between gap-2">
              <span class="text-xs font-medium text-sr-muted">
                {stats_card_label(row, @group_cols)}
              </span>
              <.result_status_badge
                :if={Map.has_key?(row, "status")}
                status={Map.get(row, "status")}
              />
            </div>
            <div class="text-2xl font-semibold tabular-nums text-sr-ink">
              {format_cell(Map.get(row, @primary_metric))}
            </div>
            <div :if={@primary_metric} class="text-xs text-sr-muted">
              {humanize_column(@primary_metric)}
            </div>
          </div>
        <% end %>
      </div>

      <.ui_panel>
        <div class="sr-ui-table-shell overflow-x-auto">
          <table
            id="check-results-stats-table"
            class={ui_table_class(size: "sm", zebra: true, class: "w-full")}
          >
            <thead>
              <tr>
                <th
                  :for={col <- @columns}
                  class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60"
                >
                  {humanize_column(col)}
                </th>
              </tr>
            </thead>
            <tbody>
              <%= for {row, idx} <- Enum.with_index(@results) do %>
                <tr
                  id={"check-results-stats-row-#{idx}"}
                  class="hover:bg-sr-subtle/40 transition-colors"
                >
                  <td :for={col <- @columns} class="whitespace-nowrap text-xs">
                    <.stats_cell column={col} value={Map.get(row, col)} />
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </.ui_panel>
    </div>
    """
  end

  attr :column, :string, required: true
  attr :value, :any, default: nil

  defp stats_cell(%{column: "status"} = assigns) do
    ~H"""
    <.result_status_badge status={@value} />
    """
  end

  defp stats_cell(%{column: col, value: val} = assigns)
       when col in ["check_slug", "check"] and is_binary(val) and val != "" do
    ~H"""
    <.link
      navigate={~p"/settings/declarative-checks/#{@value}"}
      class="font-mono font-medium text-sr-ink hover:underline"
    >
      {@value}
    </.link>
    """
  end

  defp stats_cell(assigns) do
    ~H"""
    <span class={[
      is_number(@value) && "font-semibold tabular-nums",
      !is_number(@value) && "font-mono"
    ]}>
      {format_cell(@value)}
    </span>
    """
  end

  attr :status, :any, default: nil

  def result_status_badge(assigns) do
    status_str = assigns.status |> to_string() |> String.trim() |> String.downcase()
    status_label = if status_str == "", do: "unknown", else: status_str
    assigns = assign(assigns, :status_str, status_label)

    ~H"""
    <span
      data-role="result-status-badge"
      data-status={@status_str}
      class={[
        "inline-flex items-center rounded-sr-control px-2 py-0.5 text-xs font-medium",
        @status_str == "healthy" && "bg-emerald-500/15 text-emerald-400",
        @status_str == "degraded" && "bg-amber-500/15 text-amber-400",
        @status_str == "down" && "bg-rose-500/15 text-rose-400",
        @status_str not in ["healthy", "degraded", "down"] && "bg-sr-subtle text-sr-muted"
      ]}
    >
      {@status_str}
    </span>
    """
  end

  def query_path(query) when is_binary(query) do
    @page_path <> "?" <> URI.encode_query(%{"q" => query})
  end

  defp row_identity(row, idx) when is_map(row) do
    case row_field(row, "id") do
      id when is_binary(id) and id != "" ->
        id

      _ ->
        "#{row_field(row, "check_slug")}:#{row_field(row, "target_key")}:#{idx}"
    end
  end

  defp row_identity(_row, idx), do: Integer.to_string(idx)

  defp stats_columns(rows) do
    keys =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    known = Enum.filter(@stats_group_order, &(&1 in keys))
    remaining = keys -- known
    known ++ Enum.sort(remaining)
  end

  defp split_stats_columns(columns, rows) do
    Enum.split_with(columns, fn col ->
      col in @stats_group_order or
        not Enum.any?(rows, fn row -> is_map(row) and is_number(Map.get(row, col)) end)
    end)
  end

  defp stats_card_label(_row, []), do: "Total"

  defp stats_card_label(row, group_cols) do
    Enum.map_join(group_cols, " / ", fn col ->
      val = Map.get(row, col)
      if is_nil(val) or val == "", do: "#{col}: -", else: to_string(val)
    end)
  end

  defp humanize_column(col) when is_binary(col) do
    col
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp row_field(row, key) when is_map(row) do
    case Map.fetch(row, key) do
      {:ok, value} -> value
      :error -> fetch_existing_atom_field(row, key)
    end
  end

  defp row_field(_, _), do: nil

  defp fetch_existing_atom_field(row, key) do
    atom_key = String.to_existing_atom(key)
    Map.get(row, atom_key)
  rescue
    ArgumentError -> nil
  end

  defp format_cell(nil), do: "-"
  defp format_cell(""), do: "-"
  defp format_cell(value) when is_binary(value), do: value
  defp format_cell(value) when is_integer(value), do: Integer.to_string(value)
  defp format_cell(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_cell(value), do: to_string(value)

  defp format_snapshots(nil), do: nil
  defp format_snapshots(snapshots) when snapshots == %{} or snapshots == [], do: nil

  defp format_snapshots(snapshots) when is_map(snapshots) or is_list(snapshots) do
    Jason.encode!(snapshots, pretty: true)
  rescue
    _ -> inspect(snapshots)
  end

  defp format_snapshots(other) when is_binary(other) do
    if String.trim(other) == "", do: nil, else: other
  end

  defp format_snapshots(_), do: nil
end
