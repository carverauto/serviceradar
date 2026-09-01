defmodule ServiceRadarWebNG.Dashboards.ReportDeliveryWorker do
  @moduledoc """
  Sends a single authored dashboard report delivery.
  """

  use Oban.Worker,
    queue: :web_maintenance,
    max_attempts: 3,
    unique: [
      fields: [:args, :worker],
      keys: [:delivery_id],
      period: :infinity,
      states: :incomplete
    ]

  import Swoosh.Email

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dashboards.DashboardReportDelivery
  alias ServiceRadar.OutboundMail
  alias ServiceRadarWebNG.Dashboards

  require Ash.Query
  require Logger

  @preview_limit 100
  @aggregate_preview_limit 10_000
  @max_report_panels 20

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => delivery_id}}) when is_binary(delivery_id) do
    actor = system_actor()

    with {:ok, delivery} <- get_delivery(actor, delivery_id),
         :ok <- ensure_deliverable(delivery),
         {:ok, delivery} <- mark_running(actor, delivery),
         {:ok, rendered} <- render_delivery(actor, delivery),
         {:ok, metadata} <- deliver_email(delivery, rendered),
         {:ok, _delivery} <- mark_sent(actor, delivery, rendered, metadata),
         {:ok, _schedule} <- mark_schedule_sent(actor, delivery.schedule) do
      :ok
    else
      {:skip, reason} ->
        Logger.debug("Dashboard report delivery skipped", reason: inspect(reason))
        :ok

      {:error, reason} ->
        record_failure(actor, delivery_id, reason)
        {:error, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:error, :missing_delivery_id}

  defp get_delivery(actor, delivery_id) do
    DashboardReportDelivery
    |> Ash.Query.for_read(:by_id, %{id: delivery_id})
    |> Ash.Query.load([:schedule, dashboard: [:panels]])
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, delivery} -> {:ok, delivery}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_deliverable(%{status: :sent}), do: {:skip, :already_sent}
  defp ensure_deliverable(%{status: "sent"}), do: {:skip, :already_sent}
  defp ensure_deliverable(%{recipients: []}), do: {:error, :no_recipients}
  defp ensure_deliverable(%{dashboard: nil}), do: {:error, :dashboard_not_found}
  defp ensure_deliverable(_delivery), do: :ok

  defp mark_running(actor, delivery) do
    delivery
    |> Ash.Changeset.for_update(:mark_running, %{}, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp render_delivery(actor, delivery) do
    dashboard = delivery.dashboard
    system_scope = %{user: actor, permissions: nil, identity_claims: %{}}

    panels =
      dashboard.panels
      |> Kernel.||([])
      |> Enum.sort_by(&{&1.position, &1.inserted_at})
      |> Enum.take(@max_report_panels)

    panel_results =
      Enum.map(panels, fn panel ->
        limit = panel_preview_limit(panel)

        {panel,
         Dashboards.preview_authored_query(system_scope, panel.srql_query,
           limit: limit,
           max_limit: limit
         )}
      end)

    {:ok,
     %{
       dashboard: dashboard,
       panels: panel_results,
       text: render_text(dashboard, panel_results),
       html: render_html(dashboard, panel_results),
       metadata: %{
         panel_count: length(panels),
         total_panel_count: length(dashboard.panels || []),
         row_count: total_row_count(panel_results)
       }
     }}
  end

  defp deliver_email(delivery, rendered) do
    email =
      new()
      |> to(delivery.recipients)
      |> from(mailer_from())
      |> subject(report_subject(rendered.dashboard.title))
      |> text_body(rendered.text)
      |> html_body(rendered.html)

    case OutboundMail.deliver(email) do
      {:ok, metadata} -> {:ok, metadata || %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_sent(actor, delivery, rendered, metadata) do
    delivery
    |> Ash.Changeset.for_update(
      :mark_sent,
      %{
        message_id: message_id(metadata),
        rendered_metadata: Map.put(rendered.metadata, :mailer_metadata, stringify(metadata))
      },
      actor: actor
    )
    |> Ash.update(actor: actor)
  end

  defp mark_schedule_sent(actor, schedule) do
    schedule
    |> Ash.Changeset.for_update(:record_delivery, %{}, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp record_failure(actor, delivery_id, reason) do
    with {:ok, delivery} <- get_delivery(actor, delivery_id) do
      _ =
        delivery
        |> Ash.Changeset.for_update(
          :mark_failed,
          %{error: inspect(reason), rendered_metadata: %{error: inspect(reason)}},
          actor: actor
        )
        |> Ash.update(actor: actor)

      if delivery.schedule do
        _ =
          delivery.schedule
          |> Ash.Changeset.for_update(:record_failure, %{last_error: inspect(reason)}, actor: actor)
          |> Ash.update(actor: actor)
      end
    end
  end

  defp render_text(dashboard, panel_results) do
    panel_text =
      Enum.map_join(panel_results, "\n\n", fn {panel, result} ->
        case result do
          {:ok, preview} ->
            """
            #{panel.title}
            Query: #{panel.srql_query}
            Rows: #{preview.row_count}
            #{render_panel_text(panel, preview)}
            """

          {:error, reason} ->
            """
            #{panel.title}
            Query failed: #{inspect(reason)}
            """
        end
      end)

    """
    #{dashboard.title}
    #{dashboard.description || ""}

    #{panel_text}
    """
  end

  defp render_html(dashboard, panel_results) do
    panels =
      Enum.map_join(panel_results, "\n", fn {panel, result} ->
        case result do
          {:ok, preview} ->
            """
            <section>
              <h2>#{escape(panel.title)}</h2>
              <p><code>#{escape(panel.srql_query)}</code></p>
              <p>Rows: #{preview.row_count}</p>
              #{render_panel_html(panel, preview)}
            </section>
            """

          {:error, reason} ->
            """
            <section>
              <h2>#{escape(panel.title)}</h2>
              <p>Query failed: #{escape(inspect(reason))}</p>
            </section>
            """
        end
      end)

    """
    <!doctype html>
    <html>
      <body>
        <h1>#{escape(dashboard.title)}</h1>
        <p>#{escape(dashboard.description || "")}</p>
        #{panels}
      </body>
    </html>
    """
  end

  defp render_table(fields, rows) do
    headers = Enum.map_join(fields, "", fn field -> "<th>#{escape(field.name)}</th>" end)

    body =
      Enum.map_join(rows, "", fn row ->
        cells =
          Enum.map_join(fields, "", fn field ->
            "<td>#{escape(format_value(Map.get(row, field.name)))}</td>"
          end)

        "<tr>#{cells}</tr>"
      end)

    "<table><thead><tr>#{headers}</tr></thead><tbody>#{body}</tbody></table>"
  end

  defp render_panel_text(%{visual_type: type} = panel, preview) when type in [:stat, "stat", :count, "count"] do
    value = report_bound_value(panel, preview, "value_field") || report_stat_value(preview)
    label = report_display_value(panel, "label", panel.title)
    unit = report_display_value(panel, "unit", "")
    "#{label}: #{format_value(value)}#{unit}"
  end

  defp render_panel_text(%{visual_type: type} = panel, preview)
       when type in [:gauge, "gauge", :availability, "availability"] do
    gauge = report_gauge_data(panel, preview)
    "#{gauge.label}: #{gauge.display}% (#{gauge.numerator}/#{gauge.denominator})"
  end

  defp render_panel_text(_panel, preview) do
    fields = preview.fields || []
    rows = Enum.take(preview.rows || [], 10)

    headers = Enum.map_join(fields, "\t", &to_string(&1.name))

    body =
      Enum.map_join(rows, "\n", fn row ->
        Enum.map_join(fields, "\t", fn field ->
          row
          |> Map.get(field.name)
          |> format_value()
        end)
      end)

    [headers, body]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp render_panel_html(%{visual_type: type} = panel, preview) when type in [:stat, "stat", :count, "count"] do
    value = report_bound_value(panel, preview, "value_field") || report_stat_value(preview)
    label = report_display_value(panel, "label", panel.title)
    unit = report_display_value(panel, "unit", "")

    """
    <div role="group" aria-label="#{escape("#{label}: #{format_value(value)}#{unit}")}">
      <strong>#{escape(format_value(value))}#{escape(unit)}</strong>
      <div>#{escape(label)}</div>
    </div>
    """
  end

  defp render_panel_html(%{visual_type: type} = panel, preview)
       when type in [:gauge, "gauge", :availability, "availability"] do
    gauge = report_gauge_data(panel, preview)

    """
    <div role="group" aria-label="#{escape(gauge.aria_label)}">
      <strong>#{escape(gauge.display)}#{escape(gauge.unit)}</strong>
      <div>#{escape(gauge.label)}</div>
      <progress value="#{gauge.percent}" max="100" aria-label="#{escape(gauge.aria_label)}"></progress>
      <div>#{escape(gauge.numerator_label)}: #{escape(gauge.numerator)} / #{escape(gauge.denominator_label)}: #{escape(gauge.denominator)}</div>
    </div>
    """
  end

  defp render_panel_html(_panel, preview), do: render_table(preview.fields, Enum.take(preview.rows, 25))

  defp report_gauge_data(panel, preview) do
    fields = preview.fields || []
    row = List.first(preview.rows || []) || %{}
    binding = panel.data_binding || %{}
    numerator_field = binding["numerator_field"] || binding["value_field"] || report_first_numeric_field(fields)
    denominator_field = binding["denominator_field"]
    numerator = report_numeric(Map.get(row, numerator_field)) || 0.0
    denominator = report_numeric(Map.get(row, denominator_field)) || 100.0
    percent = if denominator > 0, do: numerator / denominator * 100, else: numerator
    percent = percent |> max(0.0) |> min(100.0)
    label = report_display_value(panel, "label", panel.title)
    display = :erlang.float_to_binary(percent, decimals: 1)

    %{
      label: label,
      unit: report_display_value(panel, "unit", "%"),
      display: display,
      percent: percent,
      numerator: format_value(numerator),
      denominator: format_value(denominator),
      numerator_label: report_metric_label(panel, "numerator_label", numerator_field, "current"),
      denominator_label: report_metric_label(panel, "denominator_label", denominator_field, "target"),
      aria_label: "#{label}: #{display}%"
    }
  end

  defp report_bound_value(panel, preview, key) do
    field = (panel.data_binding || %{})[key]
    row = List.first(preview.rows || []) || %{}
    if is_binary(field) and field != "", do: Map.get(row, field)
  end

  defp report_stat_value(preview) do
    field = report_first_numeric_field(preview.fields || [])
    row = List.first(preview.rows || []) || %{}
    if field, do: Map.get(row, field)
  end

  defp report_first_numeric_field(fields) do
    Enum.find_value(fields, fn
      %{name: name, type: :number} -> name
      %{name: name, type: type} when type in [:integer, :float] -> name
      _ -> nil
    end)
  end

  defp report_numeric(value) when is_integer(value) or is_float(value), do: value * 1.0

  defp report_numeric(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp report_numeric(_value), do: nil

  defp report_display_value(panel, key, fallback) do
    case panel.display_config || %{} do
      %{^key => value} when is_binary(value) and value != "" -> value
      _ -> fallback || ""
    end
  end

  defp report_metric_label(panel, display_key, field, fallback) do
    case report_display_value(panel, display_key, nil) do
      "" -> report_default_metric_label(field, fallback)
      value -> value
    end
  end

  defp report_default_metric_label(field, fallback) do
    case field |> to_string() |> String.downcase() do
      value when value in ["numerator", "value", "count"] -> fallback
      value when value in ["denominator", "total", "target"] -> fallback
      _ -> report_humanize_field(field || fallback)
    end
  end

  defp report_humanize_field(nil), do: ""

  defp report_humanize_field(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp total_row_count(panel_results) do
    Enum.reduce(panel_results, 0, fn
      {_panel, {:ok, preview}}, acc -> acc + preview.row_count
      {_panel, {:error, _reason}}, acc -> acc
    end)
  end

  defp panel_preview_limit(%{visual_type: visual_type})
       when visual_type in [:stat, "stat", :count, "count", :pivot, "pivot"], do: @aggregate_preview_limit

  defp panel_preview_limit(_panel), do: @preview_limit

  defp system_actor, do: SystemActor.system(:dashboard_report_delivery)

  defp mailer_from do
    OutboundMail.from_tuple()
  end

  defp report_subject(title) do
    title =
      title
      |> to_string()
      |> String.replace(~r/[\r\n]+/, " ")
      |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, "")
      |> String.trim()

    "ServiceRadar dashboard report: #{title}"
  end

  defp message_id(%{id: id}) when is_binary(id), do: id
  defp message_id(%{"id" => id}) when is_binary(id), do: id
  defp message_id(%{message_id: id}) when is_binary(id), do: id
  defp message_id(%{"message_id" => id}) when is_binary(id), do: id
  defp message_id(_metadata), do: nil

  defp stringify(map) when is_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), inspect(value)} end)

  defp stringify(value), do: %{"value" => inspect(value)}

  defp format_value(%DateTime{} = value) do
    value
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp format_value(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_number(value), do: to_string(value)
  defp format_value(value) when is_boolean(value), do: to_string(value)
  defp format_value(nil), do: ""
  defp format_value(value), do: inspect(value)

  defp escape(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
