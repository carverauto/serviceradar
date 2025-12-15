defmodule ServiceRadarWebNGWeb.SRQLComponents do
  @moduledoc false

  use Phoenix.Component

  import ServiceRadarWebNGWeb.CoreComponents, only: [icon: 1]
  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadarWebNGWeb.SRQL.Catalog

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
  attr :columns, :list, default: nil
  attr :max_columns, :integer, default: 10
  attr :container, :boolean, default: true
  attr :class, :any, default: nil
  attr :empty_message, :string, default: "No results."

  def srql_results_table(assigns) do
    columns =
      assigns.columns
      |> normalize_columns(assigns.rows, assigns.max_columns)

    assigns = assign(assigns, :columns, columns)

    ~H"""
    <div class={[
      "overflow-x-auto",
      @container && "rounded-xl border border-base-200 bg-base-100 shadow-sm",
      @class
    ]}>
      <table id={@id} class="table table-sm table-zebra w-full">
        <thead>
          <tr>
            <%= for col <- @columns do %>
              <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60">
                {col}
              </th>
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
            <tr id={"#{@id}-row-#{idx}"} class="hover:bg-base-200/40">
              <%= for col <- @columns do %>
                <td class="whitespace-nowrap text-xs max-w-[24rem] truncate">
                  <.srql_cell col={col} value={Map.get(row, col)} />
                </td>
              <% end %>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :col, :string, required: true
  attr :value, :any, default: nil

  def srql_cell(assigns) do
    assigns =
      assigns
      |> assign(:col_key, assigns.col |> to_string() |> String.trim() |> String.downcase())
      |> assign(:formatted, format_cell(assigns.col, assigns.value))

    ~H"""
    <%= case @formatted do %>
      <% {:time, %{display: display, iso: iso}} -> %>
        <time datetime={iso} title={iso} class="font-mono text-[11px]">
          {display}
        </time>
      <% {:link, %{href: href, label: label}} -> %>
        <a href={href} target="_blank" rel="noreferrer" class="link link-hover font-mono text-[11px]">
          {label}
        </a>
      <% {:severity, %{label: label, variant: variant}} -> %>
        <.ui_badge variant={variant} size="xs">{label}</.ui_badge>
      <% {:boolean, %{label: label, variant: variant}} -> %>
        <.ui_badge variant={variant} size="xs">{label}</.ui_badge>
      <% {:text, %{value: value, title: title}} -> %>
        <span title={title}>{value}</span>
      <% {:json, %{value: value, title: title}} -> %>
        <span title={title} class="font-mono text-[11px]">{value}</span>
    <% end %>
    """
  end

  attr :viz, :any, default: :none

  def srql_auto_viz(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="min-w-0">
          <div class="text-sm font-semibold">Auto Visualization</div>
          <div class="text-xs text-base-content/70">
            A best-effort visualization inferred from the SRQL result set (beta).
          </div>
        </div>
      </:header>

      <div :if={@viz == :none} class="text-sm text-base-content/70">
        No visualization detected yet. Try a timeseries query (timestamp + numeric value) or a grouped count.
      </div>

      <.timeseries_viz :if={match?({:timeseries, _}, @viz)} viz={@viz} />
      <.categories_viz :if={match?({:categories, _}, @viz)} viz={@viz} />
    </.ui_panel>
    """
  end

  attr :viz, :any, required: true

  defp timeseries_viz(%{viz: {:timeseries, %{x: x, y: y, points: points}}} = assigns) do
    assigns =
      assigns
      |> assign(:x, x)
      |> assign(:y, y)
      |> assign(:points, points)
      |> assign(:spark, sparkline(points))

    ~H"""
    <div class="flex flex-col gap-3">
      <div class="text-xs text-base-content/60">
        Timeseries: <span class="font-mono">{@y}</span> over <span class="font-mono">{@x}</span>
      </div>

      <div class="rounded-lg border border-base-200 bg-base-100 p-3">
        <svg viewBox="0 0 400 120" class="w-full h-28">
          <polyline
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            class="text-primary"
            points={@spark}
          />
        </svg>
      </div>
    </div>
    """
  end

  defp timeseries_viz(assigns), do: assigns |> assign(:viz, :none) |> timeseries_viz()

  attr :viz, :any, required: true

  defp categories_viz(
         %{viz: {:categories, %{label: label, value: value, items: items}}} = assigns
       ) do
    max_v =
      items
      |> Enum.map(fn {_k, v} -> v end)
      |> Enum.max(fn -> 1 end)

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:value, value)
      |> assign(:items, items)
      |> assign(:max_v, max_v)

    ~H"""
    <div class="flex flex-col gap-3">
      <div class="text-xs text-base-content/60">
        Categories: <span class="font-mono">{@value}</span> by <span class="font-mono">{@label}</span>
      </div>

      <div class="flex flex-col gap-2">
        <%= for {k, v} <- @items do %>
          <div class="flex items-center gap-3">
            <div class="w-48 truncate text-sm" title={to_string(k)}>{format_category_label(k)}</div>
            <div class="flex-1">
              <div class="h-2 rounded-full bg-base-200 overflow-hidden">
                <div
                  class="h-2 bg-primary/70"
                  style={"width: #{round((v / @max_v) * 100)}%"}
                />
              </div>
            </div>
            <div class="w-20 text-right text-sm font-mono">{format_number(v)}</div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp categories_viz(assigns), do: assigns |> assign(:viz, :none) |> categories_viz()

  defp sparkline(points) when is_list(points) do
    values = Enum.map(points, fn {_dt, v} -> v end)

    case {values, Enum.min(values, fn -> 0 end), Enum.max(values, fn -> 0 end)} do
      {[], _, _} ->
        ""

      {_values, min_v, max_v} when min_v == max_v ->
        Enum.with_index(values)
        |> Enum.map(fn {_v, idx} ->
          x = idx_to_x(idx, length(values))
          "#{x},60"
        end)
        |> Enum.join(" ")

      {_values, min_v, max_v} ->
        Enum.with_index(values)
        |> Enum.map(fn {v, idx} ->
          x = idx_to_x(idx, length(values))
          y = 110 - round((v - min_v) / (max_v - min_v) * 100)
          "#{x},#{y}"
        end)
        |> Enum.join(" ")
    end
  end

  defp idx_to_x(_idx, 0), do: 0
  defp idx_to_x(0, _len), do: 0

  defp idx_to_x(idx, len) when len > 1 do
    round(idx / (len - 1) * 400)
  end

  defp format_number(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 2)
  defp format_number(v) when is_integer(v), do: Integer.to_string(v)
  defp format_number(v), do: to_string(v)

  defp srql_columns([], _max), do: []

  defp srql_columns([first | _], max) when is_map(first) and is_integer(max) and max > 0 do
    first
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
    |> Enum.take(max)
  end

  defp srql_columns(_, _max), do: []

  defp normalize_columns(nil, rows, max_columns), do: srql_columns(rows, max_columns)

  defp normalize_columns(columns, rows, max_columns) when is_list(columns) do
    columns =
      columns
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if columns == [] do
      srql_columns(rows, max_columns)
    else
      columns
    end
  end

  defp normalize_columns(_columns, rows, max_columns), do: srql_columns(rows, max_columns)

  defp format_cell(col, value) do
    col = col |> to_string() |> String.trim()

    cond do
      is_nil(value) ->
        {:text, %{value: "", title: nil}}

      is_boolean(value) ->
        {:boolean,
         %{
           label: if(value, do: "true", else: "false"),
           variant: if(value, do: "success", else: "error")
         }}

      severity_column?(col) and is_binary(value) ->
        {:severity, severity_badge(value)}

      time_column?(col) and is_binary(value) ->
        format_time_string(value)

      is_binary(value) ->
        format_text_string(value)

      is_number(value) ->
        {:text, %{value: to_string(value), title: nil}}

      is_list(value) or is_map(value) ->
        rendered =
          value
          |> inspect(limit: 5, printable_limit: 1_000)
          |> String.slice(0, 200)

        {:json, %{value: rendered, title: rendered}}

      true ->
        {:text, %{value: to_string(value), title: nil}}
    end
  end

  defp severity_column?(col) do
    col_key = col |> String.downcase()
    col_key in ["severity", "severity_text", "level", "service_status"]
  end

  defp time_column?(col) do
    col_key = col |> String.downcase()

    String.ends_with?(col_key, "_at") or String.ends_with?(col_key, "_time") or
      String.ends_with?(col_key, "_timestamp") or
      col_key in ["timestamp", "event_timestamp", "last_seen", "first_seen"]
  end

  defp severity_badge(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    variant =
      cond do
        normalized in ["critical", "fatal", "error"] -> "error"
        normalized in ["warn", "warning", "high"] -> "warning"
        normalized in ["info", "medium"] -> "info"
        normalized in ["debug", "low", "ok", "healthy"] -> "success"
        normalized in ["down", "offline", "unavailable"] -> "error"
        normalized in ["up", "online", "available"] -> "success"
        true -> "ghost"
      end

    %{label: value, variant: variant}
  end

  defp format_time_string(value) when is_binary(value) do
    value = String.trim(value)

    case parse_iso8601(value) do
      {:ok, dt, iso} ->
        {:time, %{display: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC"), iso: iso}}

      :error ->
        format_composite_string(value)
    end
  end

  defp format_text_string(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      match?({:ok, _, _}, parse_iso8601(value)) ->
        {:ok, dt, iso} = parse_iso8601(value)
        {:time, %{display: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC"), iso: iso}}

      url?(value) ->
        {:link, %{href: value, label: url_label(value)}}

      true ->
        format_composite_string(value)
    end
  end

  defp format_composite_string(value) when is_binary(value) do
    case String.split(value, ",", parts: 2) do
      [left, right] ->
        left = String.trim(left)
        right = String.trim(right)

        with {:ok, dt, _iso} <- parse_iso8601(left) do
          label = url_label(right)

          if url?(right) do
            {:text,
             %{
               value: "#{Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")} · #{label}",
               title: value
             }}
          else
            {:text,
             %{
               value: "#{Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")} · #{right}",
               title: value
             }}
          end
        else
          _ -> {:text, %{value: value, title: value}}
        end

      _ ->
        {:text, %{value: value, title: value}}
    end
  end

  defp parse_iso8601(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        :error

      true ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} ->
            {:ok, dt, DateTime.to_iso8601(dt)}

          {:error, _} ->
            case NaiveDateTime.from_iso8601(value) do
              {:ok, ndt} ->
                dt = DateTime.from_naive!(ndt, "Etc/UTC")
                {:ok, dt, DateTime.to_iso8601(dt)}

              {:error, _} ->
                :error
            end
        end
    end
  end

  defp url?(value) when is_binary(value) do
    String.starts_with?(value, "http://") or String.starts_with?(value, "https://")
  end

  defp url_label(value) when is_binary(value) do
    uri = URI.parse(value)

    host =
      case uri.host do
        nil ->
          value

        other ->
          port =
            case {uri.scheme, uri.port} do
              {"http", nil} -> nil
              {"https", nil} -> nil
              {"http", 80} -> nil
              {"https", 443} -> nil
              {_scheme, port} -> port
            end

          if is_integer(port) do
            "#{other}:#{port}"
          else
            other
          end
      end

    path =
      case uri.path do
        nil -> ""
        "/" -> ""
        other -> other
      end

    label = host <> path

    if is_binary(uri.query) and uri.query != "" do
      label <> "?…"
    else
      label
    end
  end

  defp format_category_label(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      match?({:ok, _, _}, parse_iso8601(value)) ->
        {:ok, dt, _iso} = parse_iso8601(value)
        Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")

      url?(value) ->
        url_label(value)

      true ->
        value
    end
  end

  defp format_category_label(value), do: to_string(value)

  attr :supported, :boolean, default: true
  attr :sync, :boolean, default: true
  attr :builder, :map, default: %{}

  def srql_query_builder(assigns) do
    assigns = assign_new(assigns, :builder, fn -> %{} end)

    entity = Map.get(assigns.builder, "entity", "devices")
    config = Catalog.entity(entity)
    supports_downsample = Map.get(config, :downsample, false)
    series_fields = Map.get(config, :series_fields, [])

    assigns =
      assigns
      |> assign(:entities, Catalog.entities())
      |> assign(:config, config)
      |> assign(:supports_downsample, supports_downsample)
      |> assign(:series_fields, series_fields)

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
                  <%= for e <- @entities do %>
                    <option value={e.id} selected={@builder["entity"] == e.id}>
                      {e.label}
                    </option>
                  <% end %>
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

                <div :if={@supports_downsample} class="flex flex-wrap items-center gap-4">
                  <div class="text-xs text-base-content/60 font-medium">Downsample</div>

                  <.srql_builder_pill label="Bucket">
                    <.ui_inline_select name="builder[bucket]" disabled={not @supported}>
                      <option value="" selected={(@builder["bucket"] || "") == ""}>
                        (none)
                      </option>
                      <option value="15s" selected={@builder["bucket"] == "15s"}>15s</option>
                      <option value="1m" selected={@builder["bucket"] == "1m"}>1m</option>
                      <option value="5m" selected={@builder["bucket"] == "5m"}>5m</option>
                      <option value="15m" selected={@builder["bucket"] == "15m"}>15m</option>
                      <option value="1h" selected={@builder["bucket"] == "1h"}>1h</option>
                      <option value="6h" selected={@builder["bucket"] == "6h"}>6h</option>
                      <option value="1d" selected={@builder["bucket"] == "1d"}>1d</option>
                    </.ui_inline_select>
                  </.srql_builder_pill>

                  <.srql_builder_pill label="Agg">
                    <.ui_inline_select name="builder[agg]" disabled={not @supported}>
                      <option value="avg" selected={(@builder["agg"] || "avg") == "avg"}>avg</option>
                      <option value="min" selected={@builder["agg"] == "min"}>min</option>
                      <option value="max" selected={@builder["agg"] == "max"}>max</option>
                      <option value="sum" selected={@builder["agg"] == "sum"}>sum</option>
                      <option value="count" selected={@builder["agg"] == "count"}>count</option>
                    </.ui_inline_select>
                  </.srql_builder_pill>

                  <.srql_builder_pill label="Series">
                    <%= if @series_fields == [] do %>
                      <.ui_inline_input
                        type="text"
                        name="builder[series]"
                        value={@builder["series"] || ""}
                        placeholder="field"
                        class="w-40 placeholder:text-base-content/40"
                        disabled={not @supported}
                      />
                    <% else %>
                      <.ui_inline_select name="builder[series]" disabled={not @supported}>
                        <option value="" selected={(@builder["series"] || "") == ""}>
                          (none)
                        </option>
                        <%= for field <- @series_fields do %>
                          <option value={field} selected={@builder["series"] == field}>
                            {field}
                          </option>
                        <% end %>
                      </.ui_inline_select>
                    <% end %>
                  </.srql_builder_pill>
                </div>

                <div class="flex flex-col gap-3">
                  <div class="text-xs text-base-content/60 font-medium">Filters</div>

                  <div class="flex flex-col gap-3">
                    <%= for {filter, idx} <- Enum.with_index(Map.get(@builder, "filters", [])) do %>
                      <div class="flex items-center gap-3">
                        <.srql_builder_pill label="Filter">
                          <%= if @config.filter_fields == [] do %>
                            <.ui_inline_input
                              type="text"
                              name={"builder[filters][#{idx}][field]"}
                              value={filter["field"] || ""}
                              placeholder="field"
                              class="w-40 placeholder:text-base-content/40"
                              disabled={not @supported}
                            />
                          <% else %>
                            <.ui_inline_select
                              name={"builder[filters][#{idx}][field]"}
                              disabled={not @supported}
                            >
                              <%= for field <- @config.filter_fields do %>
                                <option value={field} selected={filter["field"] == field}>
                                  {field}
                                </option>
                              <% end %>
                            </.ui_inline_select>
                          <% end %>

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
