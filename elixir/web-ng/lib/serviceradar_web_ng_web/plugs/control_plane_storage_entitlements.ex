defmodule ServiceRadarWebNGWeb.Plugs.ControlPlaneStorageEntitlements do
  @moduledoc """
  Private storage-entitlement, closed-day usage report, and held-object manifest
  transport on the cluster-only control-plane runtime listener (`F.4`, `F.6`, `F.9`).

  All routes under `/v1/storage/*` require `:entitlements` purpose authentication
  (`X-ServiceRadar-Control-Plane-Authorization`, `X-ServiceRadar-Deployment-Ref`,
  and `X-ServiceRadar-Entitlement-Generation`) enforced upstream by
  `ServiceRadarWebNGWeb.Plugs.ControlPlaneRuntimeAuth`.
  """
  @behaviour Plug

  import Plug.Conn

  alias Ash.Error.Invalid
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.RecordingHolds
  alias ServiceRadar.Storage.StorageEntitlements
  alias ServiceRadar.Storage.StorageUsageReports
  alias ServiceRadarWebNGWeb.ControlPlaneJSON

  @body_limit 16_384
  @max_usage_days 31

  @conflict_reasons [
    :entitlement_revision_stale,
    :entitlement_revision_conflict,
    :entitlement_deployment_mismatch,
    :entitlement_installation_mismatch,
    :entitlement_generation_stale,
    :self_hosted_install
  ]

  @bad_request_reasons [
    :invalid_storage_entitlement,
    :invalid_entitlement,
    :invalid_entitlement_document,
    :invalid_schema_version,
    :unsupported_schema_version,
    :unknown_field,
    :invalid_field,
    :invalid_usage_query,
    :invalid_usage_date_range,
    :invalid_date,
    :invalid_from_date,
    :invalid_to_date,
    :invalid_date_range,
    :date_range_too_large,
    :unclosed_day,
    :future_or_open_day,
    :invalid_hold_manifest_params,
    :invalid_hold_manifest_cursor,
    :invalid_cursor,
    :invalid_limit,
    :invalid_manifest_query
  ]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case Enum.map(conn.path_info, &URI.decode/1) do
      ["v1", "storage", "entitlement"] -> entitlement(conn)
      ["v1", "storage", "usage"] -> usage(conn)
      ["v1", "storage", "holds"] -> holds(conn)
      ["v1", "storage" | _rest] -> respond(conn, 404, %{status: "not_found"})
      _ -> conn
    end
  end

  defp entitlement(%{method: "PUT"} = conn) do
    case ControlPlaneJSON.read(conn, @body_limit) do
      {:ok, document, conn} ->
        result =
          StorageEntitlements.apply_document(installation(conn), document, actor: actor())

        respond_entitlement_result(conn, result)

      {:error, status, reason, conn} ->
        respond(conn, status, %{status: reason})
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] ->
      respond(conn, 503, %{status: "storage_entitlement_unavailable"})
  end

  defp entitlement(%{method: "GET"} = conn) do
    result = StorageEntitlements.status(installation(conn), actor: actor())
    respond_entitlement_result(conn, result)
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] ->
      respond(conn, 503, %{status: "storage_entitlement_unavailable"})
  end

  defp entitlement(conn), do: respond(conn, 404, %{status: "not_found"})

  defp usage(%{method: "GET"} = conn) do
    conn = fetch_query_params(conn)

    case validate_usage_query_params(conn.query_params) do
      {:ok, query_params} ->
        result = StorageUsageReports.query_closed_days(query_params, actor: actor())
        respond_query_result(conn, result, "storage_usage_unavailable")

      {:error, reason} ->
        respond(conn, 400, %{status: to_string(reason)})
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] ->
      respond(conn, 503, %{status: "storage_usage_unavailable"})
  end

  defp usage(conn), do: respond(conn, 404, %{status: "not_found"})

  defp holds(%{method: "GET"} = conn) do
    conn = fetch_query_params(conn)

    case validate_holds_query_params(conn.query_params) do
      {:ok, query_params} ->
        result = RecordingHolds.held_objects_manifest(query_params, actor: actor())
        respond_query_result(conn, result, "hold_manifest_unavailable")

      {:error, reason} ->
        respond(conn, 400, %{status: to_string(reason)})
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] ->
      respond(conn, 503, %{status: "hold_manifest_unavailable"})
  end

  defp holds(conn), do: respond(conn, 404, %{status: "not_found"})

  defp validate_usage_query_params(params) when is_map(params) do
    unknown_keys = Map.keys(params) -- ["from", "to"]

    with true <- unknown_keys == [],
         {:ok, from_date} <- parse_iso_date(Map.get(params, "from"), :invalid_from_date),
         {:ok, to_date} <- parse_optional_iso_date(Map.get(params, "to"), :invalid_to_date),
         :ok <- validate_closed_date_bounds(from_date, to_date) do
      {:ok, Map.take(params, ["from", "to"])}
    else
      false -> {:error, :invalid_usage_query}
      {:error, _} = err -> err
    end
  end

  defp parse_iso_date(raw, err_atom) when is_binary(raw) and byte_size(raw) == 10 do
    case Date.from_iso8601(raw) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, err_atom}
    end
  end

  defp parse_iso_date(_, err_atom), do: {:error, err_atom}

  defp parse_optional_iso_date(nil, _err_atom), do: {:ok, nil}
  defp parse_optional_iso_date("", _err_atom), do: {:error, :invalid_to_date}
  defp parse_optional_iso_date(raw, err_atom), do: parse_iso_date(raw, err_atom)

  defp validate_closed_date_bounds(from_date, to_date) do
    today = Date.utc_today()
    effective_to = to_date || Date.add(today, -1)

    cond do
      Date.compare(from_date, today) != :lt ->
        {:error, :unclosed_day}

      not is_nil(to_date) and Date.compare(to_date, today) != :lt ->
        {:error, :unclosed_day}

      not is_nil(to_date) and Date.before?(to_date, from_date) ->
        {:error, :invalid_date_range}

      Date.diff(effective_to, from_date) + 1 > @max_usage_days ->
        {:error, :date_range_too_large}

      true ->
        :ok
    end
  end

  defp validate_holds_query_params(params) when is_map(params) do
    unknown_keys = Map.keys(params) -- ["cursor", "limit"]

    if unknown_keys == [] do
      case Map.get(params, "limit") do
        nil ->
          {:ok, Map.take(params, ["cursor", "limit"])}

        raw when is_binary(raw) ->
          case Integer.parse(raw) do
            {n, ""} when n >= 1 and n <= 100 ->
              if raw == Integer.to_string(n) do
                {:ok, Map.put(Map.take(params, ["cursor"]), "limit", n)}
              else
                {:error, :invalid_limit}
              end

            _ ->
              {:error, :invalid_limit}
          end

        _ ->
          {:error, :invalid_limit}
      end
    else
      {:error, :invalid_manifest_query}
    end
  end

  defp respond_entitlement_result(conn, {:ok, projection}) when is_map(projection) do
    respond(conn, 200, projection)
  end

  defp respond_entitlement_result(conn, {:error, reason}) when reason in @conflict_reasons do
    respond(conn, 409, %{status: to_string(reason)})
  end

  defp respond_entitlement_result(conn, {:error, {reason, _detail}}) when reason in @conflict_reasons do
    respond(conn, 409, %{status: to_string(reason)})
  end

  defp respond_entitlement_result(conn, {:error, reason}) when reason in @bad_request_reasons do
    respond(conn, 400, %{status: to_string(reason)})
  end

  defp respond_entitlement_result(conn, {:error, {reason, _detail}}) when reason in @bad_request_reasons do
    respond(conn, 400, %{status: to_string(reason)})
  end

  defp respond_entitlement_result(conn, {:error, {:invalid_field, _field, _msg}}) do
    respond(conn, 400, %{status: "invalid_entitlement"})
  end

  defp respond_entitlement_result(conn, {:error, %Invalid{}}) do
    respond(conn, 400, %{status: "invalid_entitlement"})
  end

  defp respond_entitlement_result(conn, {:error, _reason}) do
    respond(conn, 503, %{status: "storage_entitlement_unavailable"})
  end

  defp respond_query_result(conn, {:ok, payload}, _fallback) when is_map(payload) do
    respond(conn, 200, payload)
  end

  defp respond_query_result(conn, {:error, reason}, _fallback) when reason in @conflict_reasons do
    respond(conn, 409, %{status: to_string(reason)})
  end

  defp respond_query_result(conn, {:error, reason}, _fallback) when reason in @bad_request_reasons do
    respond(conn, 400, %{status: to_string(reason)})
  end

  defp respond_query_result(conn, {:error, {reason, _detail}}, _fallback) when reason in @bad_request_reasons do
    respond(conn, 400, %{status: to_string(reason)})
  end

  defp respond_query_result(conn, {:error, _reason}, fallback) do
    respond(conn, 503, %{status: fallback})
  end

  defp installation(conn), do: conn.private.control_plane_entitlement_installation
  defp actor, do: SystemActor.system(:storage_entitlement_control)

  defp respond(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
