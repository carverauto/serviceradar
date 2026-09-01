defmodule ServiceRadarWebNGWeb.ArmisNorthboundRunExportController do
  @moduledoc "Exports the immutable per-source-ID Armis northbound ledger as CSV."

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Integrations.IntegrationUpdateRun
  alias ServiceRadar.Integrations.IntegrationUpdateRunTarget
  alias ServiceRadarWebNG.RBAC

  require Ash.Query

  @columns ~w(run_id collection_id source_object_id canonical_device_uid eligibility outcome reason is_available metadata)
  @page_size 1_000

  def csv(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    actor = scope.user

    with true <- RBAC.can?(scope, "settings.integrations.manage"),
         {:ok, %{run_type: :armis_northbound} = run} <-
           IntegrationUpdateRun.get_by_id(id, actor: actor) do
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header(
        "content-disposition",
        "attachment; filename=\"armis-northbound-#{run.id}.csv\""
      )
      |> send_chunked(200)
      |> stream_csv(run, actor)
    else
      false -> send_resp(conn, 403, "forbidden")
      _ -> send_resp(conn, 404, "northbound run not found")
    end
  end

  defp stream_csv(conn, run, actor) do
    case chunk(conn, csv_row(@columns)) do
      {:ok, conn} ->
        stream_target_pages(conn, run, actor, nil)

      {:error, _reason} ->
        conn
    end
  end

  defp stream_target_pages(conn, run, actor, after_source_object_id) do
    case target_page(run.id, actor, after_source_object_id) do
      {:ok, targets} ->
        case stream_targets(conn, run, targets) do
          {:ok, conn} when length(targets) == @page_size ->
            stream_target_pages(conn, run, actor, List.last(targets).source_object_id)

          {:ok, conn} ->
            conn

          {:halt, conn} ->
            conn
        end

      {:error, _reason} ->
        conn
    end
  end

  defp target_page(run_id, actor, after_source_object_id) do
    query =
      IntegrationUpdateRunTarget
      |> Ash.Query.for_read(:by_run, %{integration_update_run_id: run_id}, actor: actor)
      |> Ash.Query.limit(@page_size)

    query =
      if after_source_object_id do
        Ash.Query.filter(query, source_object_id > ^after_source_object_id)
      else
        query
      end

    Ash.read(query, actor: actor)
  end

  defp stream_targets(conn, run, targets) do
    Enum.reduce_while(targets, {:ok, conn}, fn target, {:ok, conn} ->
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
        {:ok, conn} -> {:cont, {:ok, conn}}
        {:error, _reason} -> {:halt, {:halt, conn}}
      end
    end)
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
