defmodule ServiceRadarWebNGWeb.ArmisNorthboundRunExportController do
  @moduledoc "Exports the immutable per-source-ID Armis northbound ledger as CSV."

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Integrations.IntegrationUpdateRun
  alias ServiceRadar.Integrations.IntegrationUpdateRunTarget
  alias ServiceRadarWebNG.RBAC

  @columns ~w(run_id collection_id source_object_id canonical_device_uid eligibility outcome reason is_available metadata)

  def csv(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    actor = scope.user

    with true <- RBAC.can?(scope, "settings.integrations.manage"),
         {:ok, %{run_type: :armis_northbound} = run} <-
           IntegrationUpdateRun.get_by_id(id, actor: actor),
         {:ok, targets} <- IntegrationUpdateRunTarget.list_by_run(run.id, actor: actor) do
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header(
        "content-disposition",
        "attachment; filename=\"armis-northbound-#{run.id}.csv\""
      )
      |> send_chunked(200)
      |> stream_csv(run, targets)
    else
      false -> send_resp(conn, 403, "forbidden")
      _ -> send_resp(conn, 404, "northbound run not found")
    end
  end

  defp stream_csv(conn, run, targets) do
    case chunk(conn, csv_row(@columns)) do
      {:ok, conn} ->
        Enum.reduce_while(targets, conn, fn target, conn ->
          values = [
            run.id,
            target.collection_id,
            target.source_object_id,
            target.canonical_device_uid,
            target.eligibility,
            target.outcome,
            target.reason,
            target.is_available,
            Jason.encode!(target.metadata || %{})
          ]

          case chunk(conn, csv_row(values)) do
            {:ok, conn} -> {:cont, conn}
            {:error, _reason} -> {:halt, conn}
          end
        end)

      {:error, _reason} ->
        conn
    end
  end

  defp csv_row(values), do: Enum.map_join(values, ",", &csv_cell/1) <> "\r\n"

  defp csv_cell(nil), do: "\"\""

  defp csv_cell(value) do
    value = to_string(value)

    value =
      if String.starts_with?(value, ["=", "+", "-", "@"]) do
        "'" <> value
      else
        value
      end

    "\"" <> String.replace(value, "\"", "\"\"") <> "\""
  end
end
