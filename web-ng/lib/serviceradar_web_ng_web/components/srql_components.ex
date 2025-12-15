defmodule ServiceRadarWebNGWeb.SRQLComponents do
  @moduledoc false

  use Phoenix.Component

  import ServiceRadarWebNGWeb.CoreComponents, only: [icon: 1]
  import ServiceRadarWebNGWeb.UIComponents

  attr :query, :string, default: nil
  attr :draft, :string, default: nil
  attr :loading, :boolean, default: false
  attr :builder_available, :boolean, default: true
  attr :builder_open, :boolean, default: false
  attr :builder_supported, :boolean, default: true
  attr :builder_sync, :boolean, default: true
  attr :builder, :map, default: %{}

  def srql_query_bar(assigns) do
    assigns =
      assigns
      |> assign_new(:draft, fn -> assigns.query end)
      |> assign_new(:builder, fn -> %{} end)

    ~H"""
    <div class="w-full max-w-4xl">
      <form
        phx-change="srql_change"
        phx-submit="srql_submit"
        class="flex items-center gap-2 w-full"
        autocomplete="off"
      >
        <div class="flex-1 min-w-0">
          <.ui_input
            type="text"
            name="q"
            value={@draft || ""}
            placeholder="SRQL query (e.g. in:devices time:last_7d sort:last_seen:desc limit:100)"
            mono
            class="w-full text-xs"
          />
        </div>

        <.ui_icon_button
          :if={@builder_available}
          active={@builder_open}
          aria-label="Toggle query builder"
          title="Query builder"
          phx-click="srql_builder_toggle"
        >
          <.icon name="hero-adjustments-horizontal" class="size-4" />
        </.ui_icon_button>

        <.ui_button variant="primary" size="sm" type="submit">
          <span :if={@loading} class="loading loading-spinner loading-xs" /> Run
        </.ui_button>
      </form>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, default: []
  attr :max_columns, :integer, default: 10
  attr :empty_message, :string, default: "No results."

  def srql_results_table(assigns) do
    columns = srql_columns(assigns.rows, assigns.max_columns)
    assigns = assign(assigns, :columns, columns)

    ~H"""
    <div class="overflow-x-auto rounded-xl border border-base-200 bg-base-100 shadow-sm">
      <table id={@id} class="table table-sm w-full">
        <thead>
          <tr>
            <%= for col <- @columns do %>
              <th class="whitespace-nowrap">{col}</th>
            <% end %>
          </tr>
        </thead>
        <tbody>
          <tr :if={@rows == []}>
            <td
              colspan={max(length(@columns), 1)}
              class="text-sm text-base-content/60 py-8 text-center"
            >
              {@empty_message}
            </td>
          </tr>

          <%= for {row, idx} <- Enum.with_index(@rows) do %>
            <tr id={"#{@id}-row-#{idx}"}>
              <%= for col <- @columns do %>
                <td class="whitespace-nowrap">
                  {srql_cell(Map.get(row, col))}
                </td>
              <% end %>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  defp srql_columns([], _max), do: []

  defp srql_columns([first | _], max) when is_map(first) and is_integer(max) and max > 0 do
    first
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
    |> Enum.take(max)
  end

  defp srql_columns(_, _max), do: []

  defp srql_cell(nil), do: ""
  defp srql_cell(true), do: "true"
  defp srql_cell(false), do: "false"
  defp srql_cell(value) when is_binary(value), do: value
  defp srql_cell(value) when is_number(value), do: to_string(value)
  defp srql_cell(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp srql_cell(%NaiveDateTime{} = dt), do: NaiveDateTime.to_string(dt)

  defp srql_cell(value) when is_list(value) or is_map(value) do
    value
    |> inspect(limit: 5, printable_limit: 1_000)
    |> String.slice(0, 200)
  end

  defp srql_cell(value), do: to_string(value)

  attr :supported, :boolean, default: true
  attr :sync, :boolean, default: true
  attr :builder, :map, default: %{}

  def srql_query_builder(assigns) do
    assigns = assign_new(assigns, :builder, fn -> %{} end)

    ~H"""
    <.ui_panel>
      <:header>
        <div class="min-w-0">
          <div class="text-sm font-semibold">Query Builder</div>
          <div class="text-xs text-base-content/70">
            Compose a query visually. SRQL text remains the source of truth.
          </div>
        </div>

        <div class="shrink-0 flex items-center gap-2">
          <.ui_badge :if={not @supported} variant="warning" size="sm">Limited</.ui_badge>
          <.ui_badge :if={@supported and not @sync} size="sm">Not applied</.ui_badge>

          <.ui_button
            :if={not @supported or not @sync}
            size="sm"
            variant="ghost"
            type="button"
            phx-click="srql_builder_apply"
          >
            Replace query
          </.ui_button>
        </div>
      </:header>

      <div :if={not @supported} class="mb-3 text-xs text-warning">
        This SRQL query can’t be fully represented by the builder yet. The builder won’t overwrite your query unless you
        click “Replace query”.
      </div>

      <form phx-change="srql_builder_change" autocomplete="off" class="overflow-x-auto">
        <div class="min-w-[880px]">
          <div class="flex items-start gap-10">
            <div class="flex flex-col items-start gap-5">
              <.srql_builder_pill label="In" root>
                <.ui_inline_select name="builder[entity]" disabled={not @supported}>
                  <option value="devices" selected={@builder["entity"] == "devices"}>
                    Devices
                  </option>
                  <option value="pollers" selected={@builder["entity"] == "pollers"}>
                    Pollers
                  </option>
                </.ui_inline_select>
              </.srql_builder_pill>

              <div class="pl-10 border-l-2 border-primary/30 flex flex-col gap-5">
                <.srql_builder_pill label="Time">
                  <.ui_inline_select name="builder[time]" disabled={not @supported}>
                    <option value="" selected={(@builder["time"] || "") == ""}>Any</option>
                    <option value="last_1h" selected={@builder["time"] == "last_1h"}>
                      Last 1h
                    </option>
                    <option value="last_24h" selected={@builder["time"] == "last_24h"}>
                      Last 24h
                    </option>
                    <option value="last_7d" selected={@builder["time"] == "last_7d"}>
                      Last 7d
                    </option>
                    <option value="last_30d" selected={@builder["time"] == "last_30d"}>
                      Last 30d
                    </option>
                  </.ui_inline_select>
                </.srql_builder_pill>

                <div class="flex flex-col gap-3">
                  <div class="text-xs text-base-content/60 font-medium">Filters</div>

                  <div class="flex flex-col gap-3">
                    <%= for {filter, idx} <- Enum.with_index(Map.get(@builder, "filters", [])) do %>
                      <div class="flex items-center gap-3">
                        <.srql_builder_pill label="Filter">
                          <.ui_inline_select
                            name={"builder[filters][#{idx}][field]"}
                            disabled={not @supported}
                          >
                            <%= if @builder["entity"] == "pollers" do %>
                              <option value="poller_id" selected={filter["field"] == "poller_id"}>
                                poller_id
                              </option>
                              <option value="status" selected={filter["field"] == "status"}>
                                status
                              </option>
                              <option
                                value="component_id"
                                selected={filter["field"] == "component_id"}
                              >
                                component_id
                              </option>
                              <option
                                value="registration_source"
                                selected={filter["field"] == "registration_source"}
                              >
                                registration_source
                              </option>
                            <% else %>
                              <option value="hostname" selected={filter["field"] == "hostname"}>
                                hostname
                              </option>
                              <option value="ip" selected={filter["field"] == "ip"}>ip</option>
                              <option value="device_id" selected={filter["field"] == "device_id"}>
                                device_id
                              </option>
                              <option value="poller_id" selected={filter["field"] == "poller_id"}>
                                poller_id
                              </option>
                              <option value="agent_id" selected={filter["field"] == "agent_id"}>
                                agent_id
                              </option>
                            <% end %>
                          </.ui_inline_select>

                          <.ui_inline_select
                            name={"builder[filters][#{idx}][op]"}
                            disabled={not @supported}
                            class="text-xs text-base-content/70"
                          >
                            <option
                              value="contains"
                              selected={(filter["op"] || "contains") == "contains"}
                            >
                              contains
                            </option>
                            <option value="not_contains" selected={filter["op"] == "not_contains"}>
                              does not contain
                            </option>
                            <option value="equals" selected={filter["op"] == "equals"}>
                              equals
                            </option>
                            <option value="not_equals" selected={filter["op"] == "not_equals"}>
                              does not equal
                            </option>
                          </.ui_inline_select>

                          <.ui_inline_input
                            type="text"
                            name={"builder[filters][#{idx}][value]"}
                            value={filter["value"] || ""}
                            placeholder="value"
                            class="placeholder:text-base-content/40 w-56"
                            disabled={not @supported}
                          />
                        </.srql_builder_pill>

                        <.ui_icon_button
                          size="xs"
                          disabled={not @supported}
                          aria-label="Remove filter"
                          title="Remove filter"
                          phx-click="srql_builder_remove_filter"
                          phx-value-idx={idx}
                        >
                          <.icon name="hero-x-mark" class="size-4" />
                        </.ui_icon_button>
                      </div>
                    <% end %>

                    <button
                      type="button"
                      class="inline-flex items-center gap-2 rounded-md border border-dashed border-primary/40 px-3 py-2 text-sm text-primary/80 hover:bg-primary/5 w-fit disabled:opacity-60"
                      phx-click="srql_builder_add_filter"
                      disabled={not @supported}
                    >
                      <.icon name="hero-plus" class="size-4" /> Add filter
                    </button>
                  </div>
                </div>

                <div class="flex items-center gap-4 pt-2">
                  <div class="text-xs text-base-content/60 font-medium">Sort</div>
                  <.srql_builder_pill label="Sort">
                    <.ui_inline_input
                      type="text"
                      name="builder[sort_field]"
                      value={@builder["sort_field"] || ""}
                      class="w-44"
                      disabled={not @supported}
                    />
                    <.ui_inline_select name="builder[sort_dir]" disabled={not @supported}>
                      <option value="desc" selected={(@builder["sort_dir"] || "desc") == "desc"}>
                        desc
                      </option>
                      <option value="asc" selected={@builder["sort_dir"] == "asc"}>asc</option>
                    </.ui_inline_select>
                  </.srql_builder_pill>

                  <div class="text-xs text-base-content/60 font-medium">Limit</div>
                  <.srql_builder_pill label="Limit">
                    <.ui_inline_input
                      type="number"
                      name="builder[limit]"
                      value={@builder["limit"] || ""}
                      min="1"
                      max="500"
                      class="w-24"
                      disabled={not @supported}
                    />
                  </.srql_builder_pill>
                </div>
              </div>
            </div>
          </div>
        </div>
      </form>
    </.ui_panel>
    """
  end

  slot :inner_block, required: true
  attr :label, :string, required: true
  attr :root, :boolean, default: false

  def srql_builder_pill(assigns) do
    ~H"""
    <div class="relative">
      <div :if={not @root} class="absolute -left-10 top-1/2 h-0.5 w-10 bg-primary/30" />
      <div class="inline-flex items-center gap-2 rounded-md border border-base-300 bg-base-100 px-3 py-2 shadow-sm">
        <.icon name="hero-check-mini" class="size-4 text-success opacity-80" />
        <span class="text-xs text-base-content/60">{@label}</span>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
