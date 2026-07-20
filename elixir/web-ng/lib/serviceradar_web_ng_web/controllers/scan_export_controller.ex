defmodule ServiceRadarWebNGWeb.ScanExportController do
  @moduledoc """
  Exports ad-hoc scan results (`adhoc_scan_results`) for a run as CSV or XLSX.
  Gated on `scans.export`.
  """
  use ServiceRadarWebNGWeb, :controller

  alias Elixlsx.Sheet
  alias Elixlsx.Workbook
  alias ServiceRadar.Scans.ScanResult
  alias ServiceRadarWebNG.RBAC

  @columns ["target_ip", "mode", "port", "available", "response_ms", "service"]

  def csv(conn, %{"id" => id}) do
    with_authorized(conn, id, fn rows ->
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header("content-disposition", "attachment; filename=\"scan-#{id}.csv\"")
      |> send_chunked(200)
      |> stream_csv(rows)
    end)
  end

  def xlsx(conn, %{"id" => id}) do
    with_authorized(conn, id, fn rows ->
      data_rows = Enum.map(rows, fn row -> Enum.map(@columns, &cell(row, &1)) end)
      sheet = %Sheet{name: "Results", rows: [@columns | data_rows]}

      case Elixlsx.write_to_memory(%Workbook{sheets: [sheet]}, "scan-#{id}.xlsx") do
        {:ok, {_name, binary}} ->
          conn
          |> put_resp_content_type("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
          |> put_resp_header("content-disposition", "attachment; filename=\"scan-#{id}.xlsx\"")
          |> send_resp(200, binary)

        _ ->
          send_resp(conn, 500, "Could not build XLSX")
      end
    end)
  end

  defp with_authorized(conn, id, fun) do
    scope = conn.assigns.current_scope

    if RBAC.can?(scope, "scans.export") do
      case ScanResult.by_scan_run(id, actor: scope.user) do
        {:ok, rows} -> fun.(Enum.sort_by(rows, &{&1.target_ip, &1.mode, &1.port}))
        _ -> send_resp(conn, 404, "scan not found")
      end
    else
      send_resp(conn, 403, "forbidden")
    end
  end

  defp stream_csv(conn, rows) do
    case chunk(conn, csv_row(@columns)) do
      {:ok, conn} ->
        Enum.reduce_while(rows, conn, fn row, conn ->
          case chunk(conn, csv_row(Enum.map(@columns, &cell(row, &1)))) do
            {:ok, conn} -> {:cont, conn}
            {:error, _} -> {:halt, conn}
          end
        end)

      {:error, _} ->
        conn
    end
  end

  defp csv_row(values), do: Enum.map_join(values, ",", &csv_cell/1) <> "\n"

  defp csv_cell(value) do
    value
    |> to_string()
    |> String.replace("\"", "\"\"")
    |> then(&"\"#{&1}\"")
  end

  defp cell(row, "port"), do: Map.get(row, :port)
  defp cell(row, "available"), do: Map.get(row, :available)
  defp cell(row, "response_ms"), do: Map.get(row, :response_ms)
  defp cell(row, key), do: Map.get(row, String.to_existing_atom(key))
end
