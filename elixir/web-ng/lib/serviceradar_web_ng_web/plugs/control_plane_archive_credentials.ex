defmodule ServiceRadarWebNGWeb.Plugs.ControlPlaneArchiveCredentials do
  @moduledoc """
  Private media-administration transport for Cloud-delivered S3 archive
  credentials (`F.8`, `design.md` `F7`).

  Stores writer, reader, and retention bucket keys exclusively in
  `platform.network_credential_secrets` (`managed_by = :control_plane`) and binds
  the matching `RecordingArchiveSettings` slot. Secret material is write-only and
  is never echoed in HTTP responses or logs.
  """
  @behaviour Plug

  import Plug.Conn

  alias Ash.Error.Invalid
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.CloudArchiveCredentials
  alias ServiceRadarWebNGWeb.ControlPlaneJSON

  @body_limit 4_096
  @allowed_roles ~w(writer reader retention)

  @forbidden_echo_keys [
    :access_key_id,
    :secret_access_key,
    :session_token,
    :secret_payload,
    :encrypted_payload,
    :secret,
    :token,
    :password,
    :private_key,
    "access_key_id",
    "secret_access_key",
    "session_token",
    "secret_payload",
    "encrypted_payload",
    "secret",
    "token",
    "password",
    "private_key"
  ]

  @conflict_reasons [
    :credential_deployment_mismatch,
    :credential_generation_stale,
    :credential_generation_conflict,
    :archive_credential_generation_stale,
    :archive_credential_generation_conflict,
    :archive_credential_deployment_mismatch,
    :archive_credential_installation_mismatch,
    :deployment_mismatch,
    :installation_mismatch,
    :media_generation_stale
  ]

  @bad_request_reasons [
    :invalid_archive_credential,
    :invalid_archive_credential_role,
    :invalid_archive_credential_payload,
    :invalid_credential_payload,
    :invalid_credential_role,
    :invalid_credential_generation,
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
      ["v1", "media", "archive-credentials", role] when role in @allowed_roles ->
        dispatch_role(conn, role)

      ["v1", "media", "archive-credentials" | _rest] ->
        respond(conn, 404, %{status: "not_found"})

      _ ->
        conn
    end
  end

  defp dispatch_role(%{method: "PUT"} = conn, role) do
    case ControlPlaneJSON.read(conn, @body_limit) do
      {:ok, document, conn} ->
        result =
          CloudArchiveCredentials.deliver(installation(conn), role, document, actor: actor())

        respond_result(conn, result)

      {:error, status, reason, conn} ->
        respond(conn, status, %{status: reason})
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] ->
      respond(conn, 503, %{status: "archive_credentials_unavailable"})
  end

  defp dispatch_role(%{method: "GET"} = conn, role) do
    result = CloudArchiveCredentials.status(installation(conn), role, actor: actor())
    respond_result(conn, result)
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] ->
      respond(conn, 503, %{status: "archive_credentials_unavailable"})
  end

  defp dispatch_role(conn, _role), do: respond(conn, 404, %{status: "not_found"})

  defp respond_result(conn, {:ok, projection}) when is_map(projection) do
    respond(conn, 200, strip_secret_keys(projection))
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
    respond(conn, 400, %{status: "invalid_archive_credential"})
  end

  defp respond_result(conn, {:error, %Invalid{}}) do
    respond(conn, 400, %{status: "invalid_archive_credential"})
  end

  defp respond_result(conn, {:error, _reason}) do
    respond(conn, 503, %{status: "archive_credentials_unavailable"})
  end

  defp strip_secret_keys(map) when is_map(map) and not is_struct(map) do
    map
    |> Map.drop(@forbidden_echo_keys)
    |> Map.new(fn {k, v} -> {k, strip_secret_keys(v)} end)
  end

  defp strip_secret_keys(list) when is_list(list), do: Enum.map(list, &strip_secret_keys/1)
  defp strip_secret_keys(other), do: other

  defp installation(conn), do: conn.private.control_plane_media_installation
  defp actor, do: SystemActor.system(:cloud_archive_credentials_control)

  defp respond(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
