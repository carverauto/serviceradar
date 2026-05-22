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
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Swoosh.Email

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dashboards.DashboardReportDelivery
  alias ServiceRadar.OutboundMail
  alias ServiceRadarWebNG.Dashboards

  require Ash.Query
  require Logger

  @preview_limit 100
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
        {panel, Dashboards.preview_authored_query(system_scope, panel.srql_query, limit: @preview_limit)}
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
            rows =
              preview.rows
              |> Enum.take(10)
              |> Enum.map_join("\n", &inspect/1)

            """
            #{panel.title}
            Query: #{panel.srql_query}
            Rows: #{preview.row_count}
            #{rows}
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
              #{render_table(preview.fields, Enum.take(preview.rows, 25))}
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

  defp total_row_count(panel_results) do
    Enum.reduce(panel_results, 0, fn
      {_panel, {:ok, preview}}, acc -> acc + preview.row_count
      {_panel, {:error, _reason}}, acc -> acc
    end)
  end

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

  defp format_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
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
