defmodule ServiceRadarWebNGWeb.SRQLComponents do
  @moduledoc false

  use Phoenix.Component

  import ServiceRadarWebNGWeb.CoreComponents, only: [icon: 1, user_time: 1]
  import ServiceRadarWebNGWeb.QueryBuilderComponents
  import ServiceRadarWebNGWeb.UIComponents

  alias Phoenix.HTML.FormField
  alias ServiceRadarWebNGWeb.FlowStatComponents
  alias ServiceRadarWebNGWeb.SRQL.Builder
  alias ServiceRadarWebNGWeb.SRQL.Catalog

  attr(:id, :string, default: nil)
  attr(:name, :string, default: nil)
  attr(:value, :string, default: nil)
  attr(:field, FormField, default: nil)
  attr(:label, :string, default: nil)
  attr(:error, :string, default: nil)
  attr(:completions, :list, default: nil)
  attr(:compact, :boolean, default: false)
  attr(:rich, :boolean, default: false)
  attr(:disabled, :boolean, default: false)
  attr(:class, :any, default: nil)
  attr(:editor_class, :any, default: nil)
  attr(:rest, :global, include: ~w(form required))

  def srql_editor(%{field: %FormField{} = field} = assigns) do
    assigns
    |> assign(:field, nil)
    |> assign(:id, assigns.id || field.id)
    |> assign(:name, assigns.name || field.name)
    |> assign(:value, assigns.value || field.value)
    |> srql_editor()
  end

  def srql_editor(assigns) do
    value = Phoenix.HTML.Form.normalize_value("text", assigns.value || "")
    id = assigns.id || "srql-editor-#{System.unique_integer([:positive])}"
    input_id = "#{id}-input"

    assigns =
      assigns
      |> assign(:id, id)
      |> assign(:input_id, input_id)
      |> assign(:value, value)
      |> assign(:completion_values, assigns.completions || srql_completions())
      |> assign(:completions_json, Jason.encode!(assigns.completions || srql_completions()))

    ~H"""
    <div class={["fieldset mb-2", @class]}>
      <label :if={@label} for={@id} class="flex items-center justify-between gap-2 mb-1">
        {@label}
      </label>
      <div
        :if={@compact}
        class="relative srql-input-frame"
        data-srql-input-frame
        style={[
          "--srql-font-family: var(--sr-font-mono);",
          "--srql-font-size: 0.875rem;",
          "--srql-line-height: 1.35rem;",
          "--srql-padding-inline: 0.85rem;",
          "--srql-padding-block: 0.5rem;"
        ]}
      >
        <input
          id={@id}
          type="text"
          name={@name}
          value={@value}
          phx-hook="SRQLInput"
          phx-debounce="150"
          autocomplete="off"
          autocorrect="off"
          autocapitalize="off"
          spellcheck="false"
          class={[
            ui_field_class(size: "sm", mono: true, class: "w-full text-sm"),
            "rounded-lg border-sr-line bg-sr-surface",
            "focus:border-sr-brand focus:outline-none focus:ring-1 focus:ring-sr-brand/30",
            "srql-input",
            @editor_class
          ]}
          disabled={@disabled}
          {@rest}
        />
        <div class="srql-input-overlay" data-srql-input-overlay aria-hidden="true"></div>
        <ul
          class="srql-dropdown hidden"
          data-srql-input-dropdown
          role="listbox"
          aria-label="SRQL completions"
        >
        </ul>
        <div class="srql-hint hidden" data-srql-input-hint aria-hidden="true"></div>
      </div>
      <textarea
        :if={!@compact and !@rich}
        id={@id}
        name={@name}
        phx-debounce="300"
        class={[
          ui_field_class(mono: true, class: "min-h-28 w-full text-sm leading-relaxed py-2.5"),
          "rounded-lg border-sr-line bg-sr-surface",
          "focus:border-sr-brand focus:outline-none focus:ring-1 focus:ring-sr-brand/30",
          @editor_class
        ]}
        disabled={@disabled}
        {@rest}
      >{@value}</textarea>
      <textarea
        :if={!@compact and @rich}
        id={@input_id}
        name={@name}
        class="sr-only"
        aria-hidden="true"
        tabindex="-1"
        disabled={@disabled}
        {@rest}
      >{@value}</textarea>
      <div
        :if={!@compact and @rich}
        id={@id}
        phx-hook="SRQLEditor"
        phx-update="ignore"
        data-input-id={@input_id}
        data-value={@value}
        data-completions={@completions_json}
        data-error={@error}
        data-compact={to_string(@compact)}
        data-disabled={to_string(@disabled)}
        class={[
          @compact && "h-9",
          !@compact && "min-h-28",
          "overflow-hidden rounded-lg border border-sr-line bg-sr-surface",
          @editor_class
        ]}
      />
      <p :if={@error} class="mt-1 text-xs text-error">{@error}</p>
    </div>
    """
  end

  attr(:query, :string, default: nil)
  attr(:draft, :string, default: nil)
  attr(:loading, :boolean, default: false)
  attr(:builder_available, :boolean, default: true)
  attr(:builder_open, :boolean, default: false)
  attr(:builder_supported, :boolean, default: true)
  attr(:builder_sync, :boolean, default: true)
  attr(:builder, :map, default: %{})

  def srql_query_bar(assigns) do
    assigns =
      assigns
      |> assign_new(:draft, fn -> assigns.query end)
      |> assign_new(:builder, fn -> %{} end)

    ~H"""
    <div class="w-full">
      <form
        id="srql-query-bar"
        phx-hook="SRQLTimeCookie"
        data-query={@query || ""}
        phx-change="srql_change"
        phx-submit="srql_submit"
        class="flex items-center gap-2 w-full"
        autocomplete="off"
      >
        <div class="flex-1 min-w-0">
          <.srql_editor
            id="srql-query-bar-editor"
            name="q"
            value={@draft || ""}
            compact
            class="mb-0"
            editor_class="w-full"
          />
        </div>

        <.ui_icon_button
          :if={String.trim(@draft || @query || "") != ""}
          aria-label="Reset SRQL filters"
          title="Reset SRQL filters"
          data-srql-reset
          phx-click="srql_reset"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </.ui_icon_button>

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
          <span :if={@loading} class="sr-ui-spinner sr-ui-spinner-xs" /> Run
        </.ui_button>
      </form>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:rows, :list, default: [])
  attr(:columns, :list, default: nil)
  attr(:max_columns, :integer, default: 10)
  attr(:container, :boolean, default: true)
  attr(:class, :any, default: nil)
  attr(:empty_message, :string, default: "No results.")
  attr(:sortable, :boolean, default: false)
  attr(:sort_target, :any, default: nil)
  attr(:sort_field, :string, default: nil)
  attr(:sort_dir, :any, default: nil)
  attr(:sort_col, :string, default: nil)
  attr(:sort_event, :string, default: nil)
  attr(:timezone, :string, required: true)

  def srql_results_table(assigns) do
    columns = normalize_columns(assigns.columns, assigns.rows, assigns.max_columns)

    columns =
      if Enum.any?(assigns.rows, fn row -> is_map(row) and Map.has_key?(row, "_sparkline") end) do
        columns ++ ["_sparkline"]
      else
        columns
      end

    assigns = assign(assigns, :columns, columns)

    ~H"""
    <div class={[
      "overflow-x-auto",
      @container && "rounded-xl border border-sr-line bg-sr-surface",
      @class
    ]}>
      <table id={@id} class={ui_table_class(size: "sm", zebra: true, class: "w-full")}>
        <thead>
          <tr>
            <%= for col <- @columns do %>
              <th
                class="whitespace-nowrap text-xs font-semibold text-sr-muted bg-sr-subtle/60"
                aria-sort={sort_aria(col, @sort_field, @sort_dir)}
              >
                <button
                  :if={(@sortable and @sort_target) && col != "_sparkline"}
                  type="button"
                  class="group inline-flex items-center gap-1 text-left hover:text-sr-ink"
                  phx-click="table_sort"
                  phx-target={@sort_target}
                  phx-value-field={col}
                  aria-label={"Sort by #{col}"}
                >
                  <span>{table_header_label(col)}</span>
                  <.icon
                    name={sort_icon(col, @sort_field, @sort_dir)}
                    class={[
                      "size-3 transition-opacity",
                      col == @sort_field && "opacity-100",
                      col != @sort_field && "opacity-30 group-hover:opacity-70"
                    ]}
                  />
                </button>
                <span :if={!((@sortable and @sort_target) && col != "_sparkline")}>
                  {table_header_label(col)}
                </span>
              </th>
            <% end %>
          </tr>
        </thead>
        <tbody>
          <tr :if={@rows == []}>
            <td
              colspan={max(length(@columns), 1)}
              class="text-sm text-sr-muted py-8 text-center"
            >
              {@empty_message}
            </td>
          </tr>

          <%= for {row, idx} <- Enum.with_index(@rows) do %>
            <tr id={"#{@id}-row-#{idx}"} class="hover:bg-sr-subtle/40">
              <%= for {col, col_idx} <- Enum.with_index(@columns) do %>
                <td class="whitespace-nowrap text-xs max-w-[24rem] truncate">
                  <%= if col == "_sparkline" do %>
                    <.srql_sparkline points={Map.get(row, "_sparkline")} />
                  <% else %>
                    <.srql_cell
                      id={"#{@id}-time-#{idx}-#{col_idx}"}
                      col={col}
                      value={Map.get(row, col)}
                      timezone={@timezone}
                    />
                  <% end %>
                </td>
              <% end %>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr(:col, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:id, :string, required: true)
  attr(:timezone, :string, required: true)

  def srql_cell(assigns) do
    assigns =
      assigns
      |> assign(:col_key, assigns.col |> to_string() |> String.trim() |> String.downcase())
      |> assign(:formatted, format_cell(assigns.col, assigns.value))

    ~H"""
    <%= case @formatted do %>
      <% {:time, %{value: value, iso: iso}} -> %>
        <.user_time
          id={@id}
          value={value}
          timezone={@timezone}
          style={:full}
          fallback={iso}
          class="font-mono text-[11px]"
        />
      <% {:composite_time, %{value: value, iso: iso, suffix: suffix, href: href, title: title}} -> %>
        <span title={title} class="inline-flex items-center gap-1 font-mono text-[11px]">
          <.user_time
            id={@id}
            value={value}
            timezone={@timezone}
            style={:full}
            fallback={iso}
          />
          <span aria-hidden="true">·</span>
          <a
            :if={href}
            href={href}
            target="_blank"
            rel="noreferrer"
            class="text-sr-brand hover:underline"
          >
            {suffix}
          </a>
          <span :if={is_nil(href)}>{suffix}</span>
        </span>
      <% {:link, %{href: href, label: label}} -> %>
        <a
          href={href}
          target="_blank"
          rel="noreferrer"
          class="text-sr-brand hover:underline font-mono text-[11px]"
        >
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

  attr(:viz, :any, default: :none)
  attr(:id, :string, required: true)
  attr(:timezone, :string, required: true)

  def srql_auto_viz(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="min-w-0">
          <div class="text-sm font-semibold">Auto Visualization</div>
          <div class="text-xs text-sr-muted">
            A best-effort visualization inferred from the SRQL result set (beta).
          </div>
        </div>
      </:header>

      <div :if={@viz == :none} class="text-sm text-sr-muted">
        No visualization detected yet. Try a timeseries query (timestamp + numeric value) or a grouped count.
      </div>

      <.timeseries_viz :if={match?({:timeseries, _}, @viz)} viz={@viz} />
      <.categories_viz
        :if={match?({:categories, _}, @viz)}
        id={@id}
        viz={@viz}
        timezone={@timezone}
      />
    </.ui_panel>
    """
  end

  attr(:viz, :any, required: true)

  defp timeseries_viz(%{viz: {:timeseries, %{x: x, y: y, points: points}}} = assigns) do
    assigns =
      assigns
      |> assign(:x, x)
      |> assign(:y, y)
      |> assign(:points, points)
      |> assign(:spark, sparkline(points))

    ~H"""
    <div class="flex flex-col gap-3">
      <div class="text-xs text-sr-muted">
        Timeseries: <span class="font-mono">{@y}</span> over <span class="font-mono">{@x}</span>
      </div>

      <div class="rounded-lg border border-sr-line bg-sr-surface p-3">
        <svg viewBox="0 0 400 120" class="w-full h-28">
          <polyline
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            class="text-sr-brand"
            points={@spark}
          />
        </svg>
      </div>
    </div>
    """
  end

  defp timeseries_viz(assigns), do: assigns |> assign(:viz, :none) |> timeseries_viz()

  attr(:viz, :any, required: true)
  attr(:id, :string, required: true)
  attr(:timezone, :string, required: true)

  defp categories_viz(%{viz: {:categories, %{label: label, value: value, items: items}}} = assigns) do
    max_v =
      items
      |> Enum.map(fn {_k, v} -> to_number(v) end)
      |> Enum.max(fn -> 1.0 end)
      |> ensure_positive_max()

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:value, value)
      |> assign(:items, items)
      |> assign(:max_v, max_v)

    ~H"""
    <div class="flex flex-col gap-3">
      <div class="text-xs text-sr-muted">
        Categories: <span class="font-mono">{@value}</span> by <span class="font-mono">{@label}</span>
      </div>

      <div class="flex flex-col gap-2">
        <%= for {{k, v}, item_index} <- Enum.with_index(@items) do %>
          <% v_num = to_number(v) %>
          <div class="flex items-center gap-3">
            <div class="w-48 truncate text-sm" title={to_string(k)}>
              <.user_time
                :if={category_time_value(k)}
                id={"#{@id}-time-#{item_index}"}
                value={category_time_value(k)}
                timezone={@timezone}
                style={:full}
                fallback={to_string(k)}
              />
              <span :if={is_nil(category_time_value(k))}>{format_category_label(k)}</span>
            </div>
            <div class="flex-1">
              <div class="h-2 rounded-full bg-sr-subtle overflow-hidden">
                <div
                  class="h-2 bg-sr-brand/70"
                  style={"width: #{max(round((v_num / @max_v) * 100), 0)}%"}
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

  defp ensure_positive_max(value) when is_number(value) and value > 0, do: value
  defp ensure_positive_max(_value), do: 1.0

  attr(:points, :list, default: [])

  def srql_sparkline(assigns) do
    assigns = assign(assigns, :spark, sparkline(assigns.points))

    ~H"""
    <div class="w-24 h-6">
      <svg viewBox="0 0 400 120" class="w-full h-full">
        <polyline
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          class="text-sr-brand"
          points={@spark}
        />
      </svg>
    </div>
    """
  end

  defp sparkline(points) when is_list(points) do
    values = Enum.map(points, fn {_dt, v} -> v end)

    case {values, Enum.min(values, fn -> 0 end), Enum.max(values, fn -> 0 end)} do
      {[], _, _} ->
        ""

      {_values, min_v, max_v} when min_v == max_v ->
        values
        |> Enum.with_index()
        |> Enum.map_join(" ", fn {_v, idx} ->
          x = idx_to_x(idx, length(values))
          "#{x},60"
        end)

      {_values, min_v, max_v} ->
        values
        |> Enum.with_index()
        |> Enum.map_join(" ", fn {v, idx} ->
          x = idx_to_x(idx, length(values))
          y = 110 - round((v - min_v) / (max_v - min_v) * 100)
          "#{x},#{y}"
        end)
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

  defp to_number(value) when is_number(value), do: value

  defp to_number(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> parsed
      :error -> 0
    end
  end

  defp to_number(_value), do: 0

  defp srql_columns([], _max), do: []

  defp srql_columns(rows, max) when is_list(rows) and is_integer(max) and max > 0 do
    Enum.reduce_while(rows, [], fn
      %{} = row, columns ->
        next =
          row
          |> Map.keys()
          |> Enum.map(&to_string/1)
          |> Enum.reduce(columns, fn key, acc ->
            if key in acc, do: acc, else: acc ++ [key]
          end)

        if length(next) >= max do
          {:halt, Enum.take(next, max)}
        else
          {:cont, next}
        end

      _row, columns ->
        {:cont, columns}
    end)
  end

  defp srql_columns(_, _max), do: []

  defp normalize_columns(nil, rows, max_columns) do
    rows
    |> srql_columns(max_columns)
    |> filter_device_id_column()
  end

  defp normalize_columns(columns, rows, max_columns) when is_list(columns) do
    columns =
      columns
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    columns =
      if columns == [] do
        srql_columns(rows, max_columns)
      else
        columns
      end

    filter_device_id_column(columns)
  end

  defp normalize_columns(_columns, rows, max_columns) do
    rows
    |> srql_columns(max_columns)
    |> filter_device_id_column()
  end

  defp sort_aria(col, sort_col, sort_dir) when col == sort_col do
    case sort_dir do
      :desc -> "descending"
      "desc" -> "descending"
      _ -> "ascending"
    end
  end

  defp sort_aria(_col, _sort_col, _sort_dir), do: nil

  defp filter_device_id_column(columns) when is_list(columns) do
    if "uid" in columns do
      Enum.reject(columns, &(&1 == "device_id"))
    else
      columns
    end
  end

  defp format_cell(col, value) do
    col = col |> to_string() |> String.trim()

    format_cell_value(col, value)
  end

  defp format_cell_value(_col, nil), do: {:text, %{value: "", title: nil}}

  defp format_cell_value(_col, value) when is_boolean(value) do
    {:boolean,
     %{
       label: if(value, do: "true", else: "false"),
       variant: if(value, do: "success", else: "error")
     }}
  end

  defp format_cell_value(col, value) when is_binary(value) do
    cond do
      severity_column?(col) -> {:severity, severity_badge(value)}
      time_column?(col) -> format_time_string(value)
      true -> format_text_string(value)
    end
  end

  defp format_cell_value(col, value) when is_number(value) do
    format_numeric_cell(col, value)
  end

  defp format_cell_value(_col, value) when is_list(value) or is_map(value) do
    rendered =
      value
      |> inspect(limit: 5, printable_limit: 1_000)
      |> String.slice(0, 200)

    {:json, %{value: rendered, title: rendered}}
  end

  defp format_cell_value(_col, value), do: {:text, %{value: to_string(value), title: nil}}

  defp format_numeric_cell(col, value) do
    raw = to_string(value)

    formatted =
      cond do
        byte_column?(col) ->
          format_bytes(value)

        unit = unit_for_numeric_column(col) ->
          FlowStatComponents.format_si(value, unit: unit)

        true ->
          format_cell_number(value)
      end

    {:text, %{value: formatted, title: if(formatted == raw, do: nil, else: raw)}}
  end

  defp byte_column?(col) do
    col
    |> to_string()
    |> String.downcase()
    |> then(&Regex.match?(~r/(^|_)(bytes?|octets?)(_|$)/, &1))
  end

  defp format_bytes(value) when is_integer(value), do: format_bytes(value * 1.0)

  defp format_bytes(value) when is_float(value) do
    abs_value = abs(value)

    cond do
      abs_value >= 1_125_899_906_842_624 -> "#{format_scaled(value / 1_125_899_906_842_624)} PiB"
      abs_value >= 1_099_511_627_776 -> "#{format_scaled(value / 1_099_511_627_776)} TiB"
      abs_value >= 1_073_741_824 -> "#{format_scaled(value / 1_073_741_824)} GiB"
      abs_value >= 1_048_576 -> "#{format_scaled(value / 1_048_576)} MiB"
      abs_value >= 1024 -> "#{format_scaled(value / 1024)} KiB"
      true -> "#{format_cell_number(value)} B"
    end
  end

  defp format_cell_number(value) when is_integer(value), do: delimit_integer(value)

  defp format_cell_number(value) when is_float(value) do
    decimals =
      cond do
        abs(value) >= 100 -> 2
        abs(value) >= 1 -> 3
        true -> 4
      end

    value
    |> :erlang.float_to_binary(decimals: decimals)
    |> trim_decimal()
    |> delimit_decimal()
  end

  defp format_scaled(value) when is_float(value) do
    value
    |> :erlang.float_to_binary(decimals: 2)
    |> trim_decimal()
  end

  defp delimit_decimal("-" <> rest), do: "-" <> delimit_decimal(rest)

  defp delimit_decimal(value) when is_binary(value) do
    case String.split(value, ".", parts: 2) do
      [integer, fraction] -> delimit_integer_string(integer) <> "." <> fraction
      [integer] -> delimit_integer_string(integer)
    end
  end

  defp delimit_integer(value) when is_integer(value) and value < 0 do
    "-" <> delimit_integer(abs(value))
  end

  defp delimit_integer(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> delimit_integer_string()
  end

  defp delimit_integer_string(value) when is_binary(value) do
    value
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join("", &Enum.join/1)
    |> String.replace(~r/(.{3})(?=.)/, "\\1,")
    |> String.reverse()
  end

  defp trim_decimal(value) when is_binary(value) do
    value
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp severity_column?(col) do
    col_key = String.downcase(col)
    col_key in ["severity", "severity_text", "level", "service_status"]
  end

  defp time_column?(col) do
    col_key = String.downcase(col)

    String.ends_with?(col_key, "_at") or String.ends_with?(col_key, "_time") or
      String.ends_with?(col_key, "_timestamp") or
      col_key in ["timestamp", "event_timestamp", "time", "last_seen", "first_seen"]
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
        {:time, %{value: dt, iso: iso}}

      :error ->
        format_composite_string(value)
    end
  end

  defp format_text_string(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      match?({:ok, _, _}, parse_iso8601(value)) ->
        {:ok, dt, iso} = parse_iso8601(value)
        {:time, %{value: dt, iso: iso}}

      url?(value) ->
        {:link, %{href: value, label: url_label(value)}}

      true ->
        format_composite_string(value)
    end
  end

  defp format_composite_string(value) when is_binary(value) do
    case String.split(value, ",", parts: 2) do
      [left, right] ->
        format_composite_parts(String.trim(left), String.trim(right), value)

      _ ->
        {:text, %{value: value, title: value}}
    end
  end

  defp format_composite_parts(left, right, original) do
    case parse_iso8601(left) do
      {:ok, dt, iso} ->
        format_composite_timestamp(dt, iso, right, original)

      _ ->
        {:text, %{value: original, title: original}}
    end
  end

  defp format_composite_timestamp(dt, iso, right, original) do
    label = if url?(right), do: url_label(right), else: right

    {:composite_time,
     %{
       value: dt,
       iso: iso,
       suffix: label,
       href: if(url?(right), do: right),
       title: original
     }}
  end

  defp parse_iso8601(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      :error
    else
      parse_iso8601_value(value)
    end
  end

  defp parse_iso8601_value(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        {:ok, dt, DateTime.to_iso8601(dt)}

      {:error, _} ->
        # Arbitrary SRQL text without an offset does not identify an instant.
        :error
    end
  end

  defp url?(value) when is_binary(value) do
    String.starts_with?(value, "http://") or String.starts_with?(value, "https://")
  end

  defp url_label(value) when is_binary(value) do
    uri = URI.parse(value)

    host = url_host_label(uri, value)
    path = url_path_label(uri)
    label = host <> path

    append_query_hint(label, uri)
  end

  defp table_header_label("_sparkline"), do: "Trend"
  defp table_header_label(col), do: col

  defp sort_icon(col, sort_field, "asc") when col == sort_field, do: "hero-chevron-up"
  defp sort_icon(col, sort_field, "desc") when col == sort_field, do: "hero-chevron-down"
  defp sort_icon(_col, _sort_field, _sort_dir), do: "hero-chevron-up-down"

  defp unit_for_numeric_column(col) do
    col_key = col |> to_string() |> String.trim() |> String.downcase()

    cond do
      col_key in ["bps", "bits_per_sec"] or String.ends_with?(col_key, "_bps") ->
        "bps"

      col_key in ["pps", "packets_per_sec"] or String.ends_with?(col_key, "_pps") ->
        "pps"

      col_key in ["bytes", "bytes_total", "total_bytes"] or String.ends_with?(col_key, "_bytes") ->
        "B"

      true ->
        nil
    end
  end

  defp url_host_label(uri, fallback) do
    case uri.host do
      nil -> fallback
      host -> maybe_append_port(host, uri)
    end
  end

  defp maybe_append_port(host, uri) do
    case {uri.scheme, uri.port} do
      {"http", nil} -> host
      {"https", nil} -> host
      {"http", 80} -> host
      {"https", 443} -> host
      {_scheme, port} when is_integer(port) -> "#{host}:#{port}"
      _ -> host
    end
  end

  defp url_path_label(uri) do
    case uri.path do
      nil -> ""
      "/" -> ""
      other -> other
    end
  end

  defp append_query_hint(label, uri) do
    if is_binary(uri.query) and uri.query != "" do
      label <> "?…"
    else
      label
    end
  end

  defp format_category_label(value) when is_binary(value) do
    value = String.trim(value)

    if url?(value) do
      url_label(value)
    else
      value
    end
  end

  defp format_category_label(value), do: to_string(value)

  defp category_time_value(value) when is_binary(value) do
    case parse_iso8601(String.trim(value)) do
      {:ok, _datetime, canonical} -> canonical
      _ -> nil
    end
  end

  defp category_time_value(_value), do: nil

  defp srql_completions, do: Catalog.completion_tokens()

  attr(:supported, :boolean, default: true)
  attr(:sync, :boolean, default: true)
  attr(:builder, :map, default: %{})
  attr(:mode_notice, :string, default: nil)

  def srql_query_builder(assigns) do
    assigns = assign_new(assigns, :builder, fn -> %{} end)
    assigns = assign_new(assigns, :mode_notice, fn -> nil end)

    entity = Map.get(assigns.builder, "entity", "devices")
    config = Catalog.entity(entity)
    supports_downsample = Map.get(config, :downsample, false)
    series_fields = Map.get(config, :series_fields, [])
    value_fields = Map.get(config, :value_fields, [])
    boolean_fields = Map.get(config, :boolean_fields, [])
    numeric_fields = Map.get(config, :numeric_fields, [])
    comparison_fields = numeric_fields ++ Map.get(config, :timestamp_fields, [])
    address_fields = Catalog.address_fields(config)
    # Mode-aware allowlist so chart mode cannot offer tag/near/geo/etc.
    filter_fields = Builder.filter_fields_for(assigns.builder) || config.filter_fields || []

    assigns =
      assigns
      |> assign(:entities, Catalog.entities())
      |> assign(:config, config)
      |> assign(:supports_downsample, supports_downsample)
      |> assign(:series_fields, series_fields)
      |> assign(:value_fields, value_fields)
      |> assign(:boolean_fields, boolean_fields)
      |> assign(:comparison_fields, comparison_fields)
      |> assign(:address_fields, address_fields)
      |> assign(:filter_fields, filter_fields)

    ~H"""
    <.ui_panel>
      <:header>
        <div class="min-w-0">
          <div class="text-sm font-semibold">Query Builder</div>
          <div class="text-xs text-sr-muted">
            Compose a query visually.
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

      <div
        :if={is_binary(@mode_notice) and @mode_notice != ""}
        class="mb-3 text-xs text-warning"
        role="status"
      >
        {@mode_notice}
      </div>

      <form phx-change="srql_builder_change" autocomplete="off" class="overflow-x-auto">
        <div class="min-w-[880px]">
          <div class="flex items-start gap-10">
            <div class="flex flex-col items-start gap-5">
              <.query_builder_pill label="In" root>
                <.ui_inline_select name="builder[entity]" disabled={not @supported}>
                  <%= for e <- @entities do %>
                    <option value={e.id} selected={@builder["entity"] == e.id}>
                      {e.label}
                    </option>
                  <% end %>
                </.ui_inline_select>
              </.query_builder_pill>

              <div class="pl-10 border-l-2 border-sr-brand/30 flex flex-col gap-5">
                <.query_builder_pill label="Time">
                  <.ui_inline_select name="builder[time]" disabled={not @supported}>
                    <option value="" selected={(@builder["time"] || "") == ""}>Any</option>
                    <%= if is_binary(@builder["time"]) and
                          String.starts_with?(@builder["time"], "[") and
                          String.ends_with?(@builder["time"], "]") do %>
                      <option value={@builder["time"]} selected>
                        Custom range
                      </option>
                    <% end %>
                    <option value="last_1h" selected={@builder["time"] == "last_1h"}>
                      Last 1h
                    </option>
                    <option value="last_6h" selected={@builder["time"] == "last_6h"}>
                      Last 6h
                    </option>
                    <option value="last_12h" selected={@builder["time"] == "last_12h"}>
                      Last 12h
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
                </.query_builder_pill>

                <div :if={@supports_downsample} class="flex flex-wrap items-center gap-4">
                  <div class="text-xs text-sr-muted font-medium">Downsample</div>

                  <.query_builder_pill label="Bucket">
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
                  </.query_builder_pill>

                  <.query_builder_pill label="Agg">
                    <.ui_inline_select name="builder[agg]" disabled={not @supported}>
                      <option value="avg" selected={(@builder["agg"] || "avg") == "avg"}>avg</option>
                      <option value="min" selected={@builder["agg"] == "min"}>min</option>
                      <option value="max" selected={@builder["agg"] == "max"}>max</option>
                      <option value="sum" selected={@builder["agg"] == "sum"}>sum</option>
                      <option value="count" selected={@builder["agg"] == "count"}>count</option>
                    </.ui_inline_select>
                  </.query_builder_pill>

                  <.query_builder_pill :if={@value_fields != []} label="Value">
                    <.ui_inline_select name="builder[value_field]" disabled={not @supported}>
                      <%= for field <- @value_fields do %>
                        <option value={field} selected={@builder["value_field"] == field}>
                          {field}
                        </option>
                      <% end %>
                    </.ui_inline_select>
                  </.query_builder_pill>

                  <.query_builder_pill label="Series">
                    <%= if @series_fields == [] do %>
                      <.ui_inline_input
                        type="text"
                        name="builder[series]"
                        value={@builder["series"] || ""}
                        placeholder="field"
                        class="w-40 placeholder:text-sr-muted"
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
                  </.query_builder_pill>
                </div>

                <div class="flex flex-col gap-3">
                  <div class="text-xs text-sr-muted font-medium">Filters</div>

                  <div class="flex flex-col gap-3">
                    <%= for {filter, idx} <- Enum.with_index(Map.get(@builder, "filters", [])) do %>
                      <% is_bool_field = (filter["field"] || "") in @boolean_fields %>
                      <% is_comparison_field =
                        (filter["field"] || "") in @comparison_fields %>
                      <% is_address_field = (filter["field"] || "") in @address_fields %>
                      <div class="flex items-center gap-3">
                        <.query_builder_pill label="Filter">
                          <%= if @filter_fields == [] do %>
                            <.ui_inline_input
                              type="text"
                              name={"builder[filters][#{idx}][field]"}
                              value={filter["field"] || ""}
                              placeholder="field"
                              class="w-40 placeholder:text-sr-muted"
                              disabled={not @supported}
                            />
                          <% else %>
                            <.ui_inline_select
                              name={"builder[filters][#{idx}][field]"}
                              disabled={not @supported}
                            >
                              <%= for field <- @filter_fields do %>
                                <option value={field} selected={filter["field"] == field}>
                                  {field}
                                </option>
                              <% end %>
                            </.ui_inline_select>
                          <% end %>

                          <%= if is_bool_field do %>
                            <%!-- Boolean fields only support equals/not_equals --%>
                            <.ui_inline_select
                              name={"builder[filters][#{idx}][op]"}
                              disabled={not @supported}
                              class="text-xs text-sr-muted"
                            >
                              <option
                                value="equals"
                                selected={(filter["op"] || "equals") == "equals"}
                              >
                                equals
                              </option>
                              <option value="not_equals" selected={filter["op"] == "not_equals"}>
                                does not equal
                              </option>
                            </.ui_inline_select>
                          <% else %>
                            <%= if is_comparison_field do %>
                              <.ui_inline_select
                                name={"builder[filters][#{idx}][op]"}
                                disabled={not @supported}
                                class="text-xs text-sr-muted"
                              >
                                <option
                                  value="equals"
                                  selected={(filter["op"] || "equals") == "equals"}
                                >
                                  equals
                                </option>
                                <option value="not_equals" selected={filter["op"] == "not_equals"}>
                                  does not equal
                                </option>
                                <option value="gt" selected={filter["op"] == "gt"}>
                                  greater than
                                </option>
                                <option value="gte" selected={filter["op"] == "gte"}>
                                  at least
                                </option>
                                <option value="lt" selected={filter["op"] == "lt"}>
                                  less than
                                </option>
                                <option value="lte" selected={filter["op"] == "lte"}>
                                  at most
                                </option>
                              </.ui_inline_select>
                            <% else %>
                              <%= if is_address_field do %>
                                <%!-- Addresses match exactly by default; `contains` on an
                                      address is a substring match (10.0.0.1 also matching
                                      110.0.0.1), so it stays available but is not first. --%>
                                <.ui_inline_select
                                  name={"builder[filters][#{idx}][op]"}
                                  disabled={not @supported}
                                  class="text-xs text-sr-muted"
                                >
                                  <option
                                    value="equals"
                                    selected={(filter["op"] || "equals") == "equals"}
                                  >
                                    equals
                                  </option>
                                  <option value="not_equals" selected={filter["op"] == "not_equals"}>
                                    does not equal
                                  </option>
                                  <option value="contains" selected={filter["op"] == "contains"}>
                                    contains
                                  </option>
                                  <option
                                    value="not_contains"
                                    selected={filter["op"] == "not_contains"}
                                  >
                                    does not contain
                                  </option>
                                </.ui_inline_select>
                              <% else %>
                                <.ui_inline_select
                                  name={"builder[filters][#{idx}][op]"}
                                  disabled={not @supported}
                                  class="text-xs text-sr-muted"
                                >
                                  <option
                                    value="contains"
                                    selected={(filter["op"] || "contains") == "contains"}
                                  >
                                    contains
                                  </option>
                                  <option
                                    value="not_contains"
                                    selected={filter["op"] == "not_contains"}
                                  >
                                    does not contain
                                  </option>
                                  <option value="equals" selected={filter["op"] == "equals"}>
                                    equals
                                  </option>
                                  <option value="not_equals" selected={filter["op"] == "not_equals"}>
                                    does not equal
                                  </option>
                                </.ui_inline_select>
                              <% end %>
                            <% end %>
                          <% end %>

                          <%= if is_bool_field do %>
                            <%!-- Boolean fields get a dropdown with true/false --%>
                            <.ui_inline_select
                              name={"builder[filters][#{idx}][value]"}
                              disabled={not @supported}
                              class="w-24"
                            >
                              <option value="true" selected={filter["value"] == "true"}>
                                true
                              </option>
                              <option value="false" selected={filter["value"] == "false"}>
                                false
                              </option>
                            </.ui_inline_select>
                          <% else %>
                            <.ui_inline_input
                              type="text"
                              name={"builder[filters][#{idx}][value]"}
                              value={filter["value"] || ""}
                              placeholder="value"
                              class="placeholder:text-sr-muted w-56"
                              disabled={not @supported}
                            />
                          <% end %>
                        </.query_builder_pill>

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
                      class="inline-flex items-center gap-2 rounded-md border border-dashed border-sr-brand/40 px-3 py-2 text-sm text-sr-brand/80 hover:bg-sr-brand/5 w-fit disabled:opacity-60"
                      phx-click="srql_builder_add_filter"
                      disabled={not @supported}
                    >
                      <.icon name="hero-plus" class="size-4" /> Add filter
                    </button>
                  </div>
                </div>

                <div class="flex items-center gap-4 pt-2">
                  <div class="text-xs text-sr-muted font-medium">Sort</div>
                  <.query_builder_pill label="Sort">
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
                  </.query_builder_pill>

                  <div class="text-xs text-sr-muted font-medium">Limit</div>
                  <.query_builder_pill label="Limit">
                    <.ui_inline_input
                      type="number"
                      name="builder[limit]"
                      value={@builder["limit"] || ""}
                      min="1"
                      max="500"
                      class="w-24"
                      disabled={not @supported}
                    />
                  </.query_builder_pill>
                </div>

                <div class="flex items-center gap-3 pt-4 mt-4 border-t border-sr-line">
                  <.ui_button variant="primary" size="sm" type="button" phx-click="srql_builder_run">
                    Run Query
                  </.ui_button>
                </div>
              </div>
            </div>
          </div>
        </div>
      </form>
    </.ui_panel>
    """
  end
end
