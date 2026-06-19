defmodule ServiceRadarWebNGWeb.AuthoredDashboardExportController do
  @moduledoc false
  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.DashboardVariables

  @export_limit 10_000

  def panel_csv(conn, %{"dashboard_id" => dashboard_id, "panel_id" => panel_id} = params) do
    scope = conn.assigns.current_scope

    with {:ok, dashboard} <- Dashboards.get_authored_dashboard(scope, dashboard_id, load: [:panels]),
         {:ok, panel} <- find_panel(dashboard, panel_id),
         {:ok, variable_values} <- decode_variables(params["vars"]),
         variables = DashboardVariables.list(dashboard),
         safe_values = DashboardVariables.values(variables, variable_values),
         {:ok, preview} <-
           Dashboards.preview_authored_query(
             scope,
             DashboardVariables.substitute(panel.srql_query, safe_values, variables),
             limit: @export_limit,
             max_limit: @export_limit
           ) do
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header("content-disposition", "attachment; filename=\"#{safe_filename(panel.title)}.csv\"")
      |> send_chunked(200)
      |> stream_csv(preview)
    else
      {:error, :not_found} ->
        send_resp(conn, 404, "Dashboard panel not found")

      {:error, reason} ->
        send_resp(conn, 422, "Could not export panel CSV: #{format_error(reason)}")
    end
  end

  defp find_panel(%{panels: panels}, panel_id) when is_list(panels) do
    case Enum.find(panels, &(to_string(&1.id) == to_string(panel_id))) do
      nil -> {:error, :not_found}
      panel -> {:ok, panel}
    end
  end

  defp find_panel(_dashboard, _panel_id), do: {:error, :not_found}

  defp decode_variables(nil), do: {:ok, %{}}
  defp decode_variables(""), do: {:ok, %{}}

  defp decode_variables(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, variables} when is_map(variables) ->
        {:ok, Map.new(variables, fn {key, variable} -> {to_string(key), to_string(variable)} end)}

      {:ok, _other} ->
        {:error, :invalid_variables}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stream_csv(conn, %{rows: rows, fields: fields}) when is_list(rows) and is_list(fields) do
    columns = Enum.map(fields, &field_name/1)

    case chunk(conn, csv_row(columns)) do
      {:ok, conn} ->
        Enum.reduce_while(rows, conn, fn row, conn ->
          values = Enum.map(columns, &Map.get(row, &1))

          case chunk(conn, csv_row(values)) do
            {:ok, conn} -> {:cont, conn}
            {:error, _reason} -> {:halt, conn}
          end
        end)

      {:error, _reason} ->
        conn
    end
  end

  defp stream_csv(conn, _preview), do: conn

  defp csv_row(values), do: Enum.map_join(values, ",", &csv_cell/1) <> "\n"

  defp field_name(%{name: name}), do: name
  defp field_name(%{"name" => name}), do: name
  defp field_name(name), do: to_string(name)

  defp csv_cell(value) do
    value
    |> format_value()
    |> String.replace("\"", "\"\"")
    |> then(&"\"#{&1}\"")
  end

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_integer(value) or is_float(value) or is_boolean(value), do: to_string(value)
  defp format_value(nil), do: ""
  defp format_value(value), do: Jason.encode!(value)

  defp safe_filename(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "dashboard-panel"
      filename -> filename
    end
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
