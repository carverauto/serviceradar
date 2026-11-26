defmodule ServiceRadarWebNGWeb.Plugs.ControlPlaneMediaWorkerGrants do
  @moduledoc """
  Execution-time scoped fragment read grant endpoint (`POST /v1/media/workers/read-grants`)
  for external media worker workloads, such as the Vantage addon's.

  Authenticated exclusively with the domain-separated `:media_worker` workload
  installation credential. Response bodies are marked `Cache-Control: no-store`
  and are never logged.
  """
  @behaviour Plug

  import Plug.Conn

  alias Ash.Error.Invalid
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.VisualWorkerReadGrants
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadarWebNGWeb.ControlPlaneJSON

  @body_limit 8_192

  @gone_reasons [
    :recording_gone,
    :source_deleted_or_quarantined,
    :catalog_entry_not_found,
    :entry_quarantined,
    :entry_deleted
  ]

  @conflict_reasons [
    :deployment_mismatch,
    :installation_mismatch,
    :media_worker_deployment_mismatch,
    :media_worker_generation_stale,
    :descriptor_mismatch,
    :descriptor_sha256_mismatch,
    :invalid_recording_descriptor,
    :fragment_not_found,
    :no_sampled_fragments,
    :archive_binding_destination_mismatch,
    :grant_egress_scope_mismatch,
    :grant_methods_not_reader_only
  ]

  @bad_request_reasons [
    :invalid_request,
    :invalid_read_grant_request,
    :too_many_fragments,
    :invalid_catalog_entry_id,
    :invalid_descriptor_sha256,
    :invalid_schema_version,
    :unsupported_schema_version,
    :unknown_field,
    :invalid_field
  ]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case Enum.map(conn.path_info, &URI.decode/1) do
      ["v1", "media", "workers", "read-grants"] ->
        dispatch(conn)

      ["v1", "media", "workers" | _rest] ->
        respond(conn, 404, %{status: "not_found"})

      _ ->
        conn
    end
  end

  defp dispatch(%{method: "POST"} = conn) do
    case ControlPlaneJSON.read(conn, @body_limit) do
      {:ok, document, conn} ->
        extra_opts = Map.get(conn.private, :control_plane_media_worker_grant_opts, [])

        result =
          apply(issuer(), :issue_read_grant, [
            installation(conn),
            document,
            Keyword.put_new(extra_opts, :actor, actor())
          ])

        respond_result(conn, result)

      {:error, status, reason, conn} ->
        respond(conn, status, %{status: reason})
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] ->
      respond(conn, 503, %{status: "media_worker_grants_unavailable"})
  end

  defp dispatch(conn), do: respond(conn, 404, %{status: "not_found"})

  defp respond_result(conn, {:ok, plan}) when is_map(plan) do
    respond(conn, 200, serialize_value(plan))
  end

  defp respond_result(conn, {:error, reason}) when reason in @gone_reasons do
    respond(conn, 410, %{status: "recording_gone"})
  end

  defp respond_result(conn, {:error, {reason, _detail}}) when reason in @gone_reasons do
    respond(conn, 410, %{status: "recording_gone"})
  end

  defp respond_result(conn, {:error, reason}) when reason in @conflict_reasons do
    respond(conn, 409, %{status: to_string(reason)})
  end

  defp respond_result(conn, {:error, {reason, _detail}}) when reason in @conflict_reasons do
    respond(conn, 409, %{status: to_string(reason)})
  end

  defp respond_result(conn, {:error, reason}) when reason in @bad_request_reasons do
    respond(conn, 400, %{status: to_string(reason)})
  end

  defp respond_result(conn, {:error, {reason, _detail}}) when reason in @bad_request_reasons do
    respond(conn, 400, %{status: to_string(reason)})
  end

  defp respond_result(conn, {:error, {:invalid_field, _field, _msg}}) do
    respond(conn, 400, %{status: "invalid_read_grant_request"})
  end

  defp respond_result(conn, {:error, %Invalid{}}) do
    respond(conn, 400, %{status: "invalid_read_grant_request"})
  end

  defp respond_result(conn, {:error, :unauthorized_worker}) do
    respond(conn, 403, %{status: "forbidden"})
  end

  defp respond_result(conn, {:error, _reason}) do
    respond(conn, 503, %{status: "media_worker_grants_unavailable"})
  end

  defp serialize_value(%CredentialBrokerGrant{} = grant), do: CredentialBrokerGrant.to_payload(grant)
  defp serialize_value(%DateTime{} = dt), do: DateTime.to_unix(dt, :second)
  defp serialize_value(struct) when is_struct(struct), do: struct

  defp serialize_value(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, serialize_value(v)} end)
  end

  defp serialize_value(list) when is_list(list), do: Enum.map(list, &serialize_value/1)
  defp serialize_value(other), do: other

  defp issuer do
    Application.get_env(
      :serviceradar_web_ng,
      :control_plane_media_worker_grants_issuer,
      VisualWorkerReadGrants
    )
  end

  defp installation(conn), do: conn.private.control_plane_media_worker_installation
  defp actor, do: SystemActor.system(:visual_worker_read_grants_control)

  defp respond(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
