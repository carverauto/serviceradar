defmodule ServiceRadarWebNGWeb.Observability.SignalDisplayComponents do
  @moduledoc false
  use Phoenix.Component

  import ServiceRadarWebNGWeb.CoreComponents, only: [icon: 1, user_time: 1]
  import ServiceRadarWebNGWeb.UIComponents

  @nanoseconds_per_second 1_000_000_000

  attr(:widgets, :list, required: true)
  attr(:id, :string, required: true)
  attr(:timezone, :string, required: true)

  def signal_display_panel(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center gap-2">
          <.icon name="hero-signal" class="size-4 text-sr-muted" />
          <span class="text-sm font-semibold text-sr-ink">Signal details</span>
        </div>
      </:header>

      <div class="space-y-5">
        <%= for {widget, widget_index} <- Enum.with_index(@widgets) do %>
          <.signal_display_widget
            id={"#{@id}-widget-#{Map.get(widget, :contract_index, widget_index)}"}
            widget={widget}
            timezone={@timezone}
          />
        <% end %>
      </div>
    </.ui_panel>
    """
  end

  attr(:widget, :map, required: true)
  attr(:id, :string, required: true)
  attr(:timezone, :string, required: true)

  def signal_display_widget(%{widget: %{type: :summary}} = assigns) do
    ~H"""
    <div class="space-y-2">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h2 class="text-base font-semibold leading-tight text-sr-ink">
          {@widget.title || "Signal event"}
        </h2>
        <.signal_severity_badge value={@widget.severity} />
      </div>
      <p :if={@widget.message} class="whitespace-pre-wrap text-sm text-sr-ink/90">
        {@widget.message}
      </p>
      <p :if={@widget.source} class="text-xs text-sr-muted">
        Source: <span class="font-mono text-sr-ink">{@widget.source}</span>
      </p>
    </div>
    """
  end

  def signal_display_widget(%{widget: %{type: :badges}} = assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2">
      <.ui_badge
        :for={{field, field_index} <- Enum.with_index(@widget.fields)}
        variant={signal_badge_variant(field)}
        size="sm"
      >
        {field.label}:
        <.user_time
          :if={temporal_value(field)}
          id={"#{@id}-field-#{field_index}-time"}
          value={temporal_value(field)}
          timezone={@timezone}
          style={:full}
          fallback={field.value}
        />
        <span :if={is_nil(temporal_value(field))}>{field.value}</span>
      </.ui_badge>
    </div>
    """
  end

  def signal_display_widget(%{widget: %{type: type}} = assigns) when type in [:facts, :timeline] do
    assigns = assign(assigns, :heading, if(type == :timeline, do: "Timeline", else: "Facts"))

    ~H"""
    <div>
      <span class="mb-3 block text-[10px] font-medium uppercase tracking-[0.14em] text-sr-muted">
        {@heading}
      </span>
      <div class="grid grid-cols-1 gap-x-6 gap-y-3 sm:grid-cols-2">
        <div
          :for={{field, field_index} <- Enum.with_index(@widget.fields)}
          class="flex min-w-0 flex-col gap-0.5"
        >
          <span class="text-[11px] text-sr-muted">{field.label}</span>
          <.link
            :if={Map.get(field, :href)}
            navigate={field.href}
            class="break-words text-sm text-sr-brand underline-offset-2 hover:underline"
            aria-label={Map.get(field, :href_label) || "Open #{field.label} #{field.value}"}
          >
            <.user_time
              :if={temporal_value(field)}
              id={"#{@id}-field-#{field_index}-time"}
              value={temporal_value(field)}
              timezone={@timezone}
              style={:full}
              fallback={field.value}
            />
            <span :if={is_nil(temporal_value(field))}>{field.value}</span>
          </.link>
          <.user_time
            :if={!Map.get(field, :href) && temporal_value(field)}
            id={"#{@id}-field-#{field_index}-time"}
            value={temporal_value(field)}
            timezone={@timezone}
            style={:full}
            fallback={field.value}
            class="break-words text-sm text-sr-ink"
          />
          <span
            :if={!Map.get(field, :href) && is_nil(temporal_value(field))}
            class="break-words text-sm text-sr-ink"
          >
            {field.value}
          </span>
        </div>
      </div>
    </div>
    """
  end

  def signal_display_widget(%{widget: %{type: :json_section}} = assigns) do
    # Prefer flattened key/value facts over raw JSON walls.
    facts =
      assigns.widget
      |> Map.get(:sections, [])
      |> Enum.with_index()
      |> Enum.flat_map(fn {section, section_index} ->
        case Map.get(section, :value) do
          %{} = map ->
            flatten_json_facts(map, nil, Map.get(section, :path) || "section-#{section_index}")

          list when is_list(list) ->
            [%{label: "Items", value: "#{length(list)} entries"}]

          _ ->
            []
        end
      end)
      |> Enum.take(24)

    assigns =
      assigns
      |> assign(:facts, facts)
      |> assign(:title, assigns.widget.title || "Details")

    ~H"""
    <div :if={@facts != []}>
      <span class="mb-3 block text-[10px] font-medium uppercase tracking-[0.14em] text-sr-muted">
        {@title}
      </span>
      <div class="grid grid-cols-1 gap-x-6 gap-y-3 sm:grid-cols-2">
        <div
          :for={{fact, fact_index} <- Enum.with_index(@facts)}
          class="flex min-w-0 flex-col gap-0.5"
        >
          <span class="text-[11px] text-sr-muted">{fact.label}</span>
          <.user_time
            :if={temporal_value(fact)}
            id={"#{@id}-fact-#{fact_index}-#{dom_segment(fact.path)}-time"}
            value={temporal_value(fact)}
            timezone={@timezone}
            style={:full}
            fallback={fact.value}
            class="break-all text-sm text-sr-ink"
          />
          <span :if={is_nil(temporal_value(fact))} class="break-all text-sm text-sr-ink">
            {fact.value}
          </span>
        </div>
      </div>
    </div>
    """
  end

  def signal_display_widget(%{widget: %{type: :table}} = assigns) do
    ~H"""
    <div>
      <span class="mb-3 block text-[10px] font-medium uppercase tracking-[0.14em] text-sr-muted">
        {@widget.title || "Rows"}
      </span>
      <div class="sr-ui-table-shell max-w-full overflow-x-auto">
        <table class={ui_table_class(size: "sm")}>
          <thead>
            <tr>
              <th :for={column <- @widget.columns}>{column.label}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{row, row_index} <- Enum.with_index(@widget.rows)}>
              <td
                :for={{cell, cell_index} <- Enum.with_index(row.values)}
                class="max-w-sm align-top"
              >
                <.user_time
                  :if={temporal_value(cell)}
                  id={"#{@id}-row-#{row_index}-cell-#{cell_index}-time"}
                  value={temporal_value(cell)}
                  timezone={@timezone}
                  style={:full}
                  fallback={cell.value}
                  class="line-clamp-3 break-words"
                />
                <span :if={is_nil(temporal_value(cell))} class="line-clamp-3 break-words">
                  {cell.value}
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  def signal_display_widget(assigns), do: ~H""

  @json_timestamp_keys MapSet.new(
                         ~w(time timestamp event_time logged_time observed_at created_at updated_at expires_at creationTimestamp updateTimestamp)
                       )
  @json_unix_nano_keys MapSet.new(~w(observed_time_unix_nano observed_at_unix_nano))

  defp flatten_json_facts(map, prefix, path_prefix) when is_map(map) do
    map
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.flat_map(fn {key, value} ->
      label =
        key
        |> to_string()
        |> String.replace("_", " ")
        |> String.split()
        |> Enum.map_join(" ", &String.capitalize/1)

      key = to_string(key)
      label = if prefix, do: "#{prefix} · #{label}", else: label
      path = "#{path_prefix}.#{key}"

      cond do
        value in [nil, "", []] ->
          []

        is_map(value) and map_size(value) == 0 ->
          []

        is_map(value) and map_size(value) <= 6 and flat_map?(value) ->
          flatten_json_facts(value, label, path)

        is_map(value) or is_list(value) ->
          []

        true ->
          [
            %{
              label: label,
              path: path,
              value: to_string(value),
              format: json_temporal_format(key)
            }
          ]
      end
    end)
  end

  defp temporal_value(%{format: "timestamp", value: value})
       when is_binary(value) or is_struct(value, DateTime) or is_struct(value, NaiveDateTime), do: value

  defp temporal_value(%{format: "unix_nano", value: value}) do
    with {:ok, unix_nano} <- parse_unix_time(value),
         seconds = Integer.floor_div(unix_nano, @nanoseconds_per_second),
         nanoseconds = Integer.mod(unix_nano, @nanoseconds_per_second),
         {:ok, datetime} <- DateTime.from_unix(seconds, :second) do
      datetime
      |> DateTime.to_iso8601()
      |> String.replace_suffix(
        "Z",
        ".#{nanoseconds |> Integer.to_string() |> String.pad_leading(9, "0")}Z"
      )
    else
      # Falco uses its top-level RFC3339 timestamp when evt.time is absent.
      # Accept that producer fallback at the display boundary without rewriting
      # the stored payload or weakening the unix-nanosecond precision path.
      _ -> temporal_value(%{format: "timestamp", value: value})
    end
  end

  defp temporal_value(_field), do: nil

  defp parse_unix_time(value) when is_integer(value), do: {:ok, value}

  defp parse_unix_time(value) when is_binary(value) do
    case Integer.parse(value) do
      {unix_time, ""} -> {:ok, unix_time}
      _ -> :error
    end
  end

  defp parse_unix_time(_value), do: :error

  defp json_temporal_format(key) do
    cond do
      MapSet.member?(@json_timestamp_keys, key) -> "timestamp"
      MapSet.member?(@json_unix_nano_keys, key) -> "unix_nano"
      true -> nil
    end
  end

  defp dom_segment(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp flat_map?(%{} = map) do
    Enum.all?(map, fn {_k, v} -> is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v) end)
  end

  attr(:value, :any, default: nil)

  defp signal_severity_badge(assigns) do
    variant = severity_variant(assigns.value)
    label = severity_label(assigns.value)

    assigns = assigns |> assign(:variant, variant) |> assign(:label, label)

    ~H"""
    <.ui_badge variant={@variant} size="sm">{@label}</.ui_badge>
    """
  end

  defp severity_variant(value) do
    case normalize_value(value) do
      value when value in ["critical", "fatal", "error"] -> "error"
      value when value in ["high", "warn", "warning"] -> "warning"
      value when value in ["medium", "info"] -> "info"
      value when value in ["low", "debug", "ok"] -> "success"
      _ -> "ghost"
    end
  end

  defp severity_label(nil), do: "—"
  defp severity_label(""), do: "—"
  defp severity_label(value) when is_binary(value), do: value
  defp severity_label(value), do: to_string(value)

  defp signal_badge_variant(%{tone: "severity", value: value}), do: severity_variant(value)
  defp signal_badge_variant(%{tone: "status", value: value}), do: status_variant(value)
  defp signal_badge_variant(%{tone: "success"}), do: "success"
  defp signal_badge_variant(%{tone: "warning"}), do: "warning"
  defp signal_badge_variant(%{tone: "error"}), do: "error"
  defp signal_badge_variant(%{tone: "info"}), do: "info"
  defp signal_badge_variant(_field), do: "ghost"

  defp status_variant(value) do
    case normalize_value(value) do
      status when status in ["success", "allowed", "ok"] -> "success"
      status when status in ["failure", "blocked", "denied", "error"] -> "error"
      status when status in ["warning", "warn"] -> "warning"
      _ -> "ghost"
    end
  end

  defp normalize_value(nil), do: ""
  defp normalize_value(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_value(value), do: value |> to_string() |> normalize_value()
end
