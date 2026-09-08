defmodule ServiceRadarWebNGWeb.Api.SourceInventoryController do
  @moduledoc "Authenticated, RBAC-scoped access to bounded source inventory snapshots."

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Inventory.SourceInventoryReader
  alias ServiceRadarWebNG.RBAC

  require Logger

  def index(conn, params) do
    with :ok <- require_permission(conn.assigns[:current_scope]),
         {:ok, response} <- source_inventory_reader().list(params) do
      json(conn, response)
    else
      {:error, :forbidden} ->
        error(conn, :forbidden, "forbidden", "You do not have permission to view source inventory")

      {:error, {:invalid_query, reason}} ->
        error(conn, :bad_request, Atom.to_string(reason), "Invalid source inventory query")

      {:error, :source_snapshot_not_found} ->
        error(conn, :not_found, "source_snapshot_not_found", "No current source inventory exists")

      {:error, :source_collection_changed} ->
        error(
          conn,
          :conflict,
          "source_collection_changed",
          "The current source inventory changed; restart pagination"
        )

      {:error, _reason} ->
        Logger.error("Source inventory API failed")
        unavailable(conn)
    end
  rescue
    exception ->
      Logger.error("Source inventory API raised #{inspect(exception.__struct__)}")
      unavailable(conn)
  end

  defp require_permission(scope) do
    if RBAC.can?(scope, "devices.view"), do: :ok, else: {:error, :forbidden}
  end

  defp source_inventory_reader do
    Application.get_env(
      :serviceradar_web_ng,
      :source_inventory_reader,
      SourceInventoryReader
    )
  end

  defp unavailable(conn) do
    error(
      conn,
      :internal_server_error,
      "source_inventory_unavailable",
      "Source inventory is temporarily unavailable"
    )
  end

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{"error" => code, "message" => message})
  end
end
