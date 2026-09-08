defmodule ServiceRadarWebNGWeb.Api.AddonFleetController do
  @moduledoc """
  Read-only API surface for the native add-on fleet health read model.

  The response deliberately exposes the derived category, stable reason code,
  and evidence age alongside the raw desired and observed versions. Consumers
  therefore do not need to reconstruct rollout semantics from raw add-on status
  records.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Plugins.AddonFleet
  alias ServiceRadarWebNG.RBAC

  require Logger

  @max_limit 500
  @allowed_params MapSet.new(["agent_uid", "addon_id", "category", "attention_only", "limit"])

  def index(conn, params) do
    with :ok <- require_permission(conn.assigns[:current_scope]),
         {:ok, filters, limit} <- parse_params(params),
         %{rows: rows} <- addon_fleet().overview(scope: conn.assigns[:current_scope]) do
      rows = AddonFleet.filter(rows, filters)

      json(conn, %{
        "api_version" => "v1",
        "schema_version" => "serviceradar.addon_fleet.v1",
        "summary" => summary_json(rows),
        "pagination" => %{
          "limit" => limit,
          "total" => length(rows),
          "has_more" => length(rows) > limit
        },
        "rows" => rows |> Enum.take(limit) |> Enum.map(&row_json/1)
      })
    else
      {:error, :forbidden} ->
        error(conn, :forbidden, "forbidden", "You do not have permission to view the add-on fleet")

      {:error, :invalid_query} ->
        error(conn, :bad_request, "invalid_query", "Invalid add-on fleet query")
    end
  rescue
    exception ->
      Logger.error("Add-on fleet API raised #{inspect(exception.__struct__)}")
      error(conn, :internal_server_error, "addon_fleet_unavailable", "Add-on fleet is temporarily unavailable")
  end

  defp require_permission(scope) do
    if RBAC.can?(scope, "settings.edge.manage"), do: :ok, else: {:error, :forbidden}
  end

  defp parse_params(params) when is_map(params) do
    if params |> Map.keys() |> MapSet.new() |> MapSet.subset?(@allowed_params) do
      with {:ok, limit} <- parse_limit(Map.get(params, "limit")) do
        {:ok, Map.take(params, ["agent_uid", "addon_id", "category", "attention_only"]), limit}
      end
    else
      {:error, :invalid_query}
    end
  end

  defp parse_params(_params), do: {:error, :invalid_query}

  defp parse_limit(nil), do: {:ok, 100}

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit > 0 and limit <= @max_limit -> {:ok, limit}
      _ -> {:error, :invalid_query}
    end
  end

  defp parse_limit(_value), do: {:error, :invalid_query}

  defp summary_json(rows) do
    rows
    |> AddonFleet.summary()
    |> Map.new(fn {category, count} -> {Atom.to_string(category), count} end)
  end

  defp row_json(row) do
    %{
      "agent_uid" => row.agent_uid,
      "agent_label" => row.agent_label,
      "addon_id" => row.addon_id,
      "addon_name" => row.addon_name,
      "assigned" => row.assigned?,
      "assigned_version" => row.assigned_version,
      "observed_state" => row.running_state,
      "observed_version" => row.running_version,
      "active" => row.active?,
      "category" => to_string(row.category),
      "reason_code" => row.reason_code,
      "evidence_age_seconds" => row.evidence_age_seconds,
      "observed_at" => iso8601(row.reported_at),
      "rollout_state" => string_or_nil(row.rollout_state),
      "update_policy" => string_or_nil(row.update_policy),
      "package_status" => string_or_nil(row.package_status),
      "degradation_reason" => row.degradation_reason
    }
  end

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(_value), do: nil

  defp string_or_nil(value) when is_atom(value), do: Atom.to_string(value)
  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp addon_fleet do
    Application.get_env(:serviceradar_web_ng, :addon_fleet_reader, AddonFleet)
  end

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{"error" => code, "message" => message})
  end
end
