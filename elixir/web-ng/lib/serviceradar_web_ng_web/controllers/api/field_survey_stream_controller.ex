defmodule ServiceRadarWebNGWeb.Api.FieldSurveyStreamController do
  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.FieldSurveyArtifactStore
  alias ServiceRadarWebNG.FieldSurveyRoomArtifacts
  alias ServiceRadarWebNG.FieldSurveySessionOwnership

  require Logger

  @max_frame_size 8 * 1024 * 1024
  @artifact_read_length 1_048_576
  @artifact_read_timeout 60_000

  def auth_check(conn, _params) do
    case conn.assigns[:current_scope] do
      %{user: %{id: user_id}} ->
        json(conn, %{ok: true, user_id: user_id})

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{ok: false, error: "unauthorized"})
    end
  end

  def rf_observations(conn, %{"session_id" => session_id}) do
    connect(conn, session_id, :rf_observations)
  end

  def pose_samples(conn, %{"session_id" => session_id}) do
    connect(conn, session_id, :pose_samples)
  end

  def spectrum_observations(conn, %{"session_id" => session_id}) do
    connect(conn, session_id, :spectrum_observations)
  end

  def room_artifacts(conn, %{"session_id" => session_id} = params) do
    case conn.assigns[:current_scope] do
      %{user: %{id: user_id}} = scope ->
        with {:ok, session_id} <- FieldSurveySessionOwnership.claim_or_verify(session_id, to_string(user_id)),
             {:ok, body, conn} <- read_artifact_body(conn),
             {:ok, artifact} <-
               FieldSurveyRoomArtifacts.store(session_id, to_string(user_id), body,
                 artifact_type: artifact_type(conn, params),
                 content_type: content_type(conn),
                 captured_at: captured_at(conn),
                 metadata: artifact_metadata(conn),
                 scope: scope
               ) do
          json(conn, %{
            ok: true,
            artifact_id: artifact.id,
            session_id: artifact.session_id,
            artifact_type: artifact.artifact_type,
            content_type: artifact.content_type,
            object_key: artifact.object_key,
            byte_size: artifact.byte_size,
            sha256: artifact.sha256,
            uploaded_at: artifact.uploaded_at
          })
        else
          {:error, :invalid_session_id} ->
            conn
            |> put_status(:bad_request)
            |> json(%{ok: false, error: "invalid_session_id"})

          {:error, :forbidden} ->
            conn
            |> put_status(:forbidden)
            |> json(%{ok: false, error: "session_owned_by_another_user"})

          {:error, :artifact_too_large} ->
            conn
            |> put_status(:payload_too_large)
            |> json(%{ok: false, error: "artifact_too_large"})

          {:error, :empty_artifact} ->
            conn
            |> put_status(:bad_request)
            |> json(%{ok: false, error: "empty_artifact"})

          {:error, reason} ->
            Logger.error("FieldSurvey room artifact upload failed: #{inspect(reason)}")

            conn
            |> put_status(:internal_server_error)
            |> json(%{ok: false, error: "artifact_upload_failed"})
        end

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{ok: false, error: "unauthorized"})
    end
  end

  defp connect(conn, session_id, stream_type) do
    case conn.assigns[:current_scope] do
      %{user: %{id: user_id}} ->
        with :ok <- validate_websocket_upgrade(conn),
             {:ok, session_id} <- FieldSurveySessionOwnership.claim_or_verify(session_id, to_string(user_id)) do
          Logger.info("Upgrading FieldSurvey #{stream_type} Arrow stream for user #{user_id}, session: #{session_id}")

          conn
          |> WebSockAdapter.upgrade(
            ServiceRadarWebNGWeb.Channels.FieldSurveyArrowStreamHandler,
            [session_id: session_id, user_id: user_id, stream_type: stream_type],
            timeout: 60_000,
            max_frame_size: @max_frame_size
          )
          |> halt()
        else
          {:error, :websocket_required} ->
            conn
            |> put_status(426)
            |> json(%{ok: false, error: "websocket_required"})

          {:error, :invalid_session_id} ->
            conn
            |> put_status(:bad_request)
            |> json(%{ok: false, error: "invalid_session_id"})

          {:error, :forbidden} ->
            conn
            |> put_status(:forbidden)
            |> json(%{ok: false, error: "session_owned_by_another_user"})

          {:error, reason} ->
            Logger.error("FieldSurvey stream ownership check failed: #{inspect(reason)}")

            conn
            |> put_status(:internal_server_error)
            |> json(%{ok: false, error: "session_ownership_check_failed"})
        end

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{ok: false, error: "unauthorized"})
    end
  end

  defp validate_websocket_upgrade(conn) do
    upgrade? =
      conn
      |> get_req_header("upgrade")
      |> Enum.any?(&(String.downcase(&1) == "websocket"))

    connection_upgrade? =
      conn
      |> get_req_header("connection")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.any?(&(String.downcase(String.trim(&1)) == "upgrade"))

    if upgrade? and connection_upgrade?, do: :ok, else: {:error, :websocket_required}
  end

  defp read_artifact_body(conn) do
    case Plug.Conn.read_body(conn,
           length: FieldSurveyArtifactStore.max_upload_bytes(),
           read_length: @artifact_read_length,
           read_timeout: @artifact_read_timeout
         ) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, _conn} -> {:error, :artifact_too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  defp artifact_type(conn, params) do
    params["artifact_type"] ||
      conn
      |> get_req_header("x-fieldsurvey-artifact-type")
      |> List.first()
  end

  defp content_type(conn) do
    conn
    |> get_req_header("content-type")
    |> List.first()
  end

  defp captured_at(conn) do
    conn
    |> get_req_header("x-fieldsurvey-captured-at-unix-nanos")
    |> List.first()
    |> parse_unix_nanos()
  end

  defp parse_unix_nanos(nil), do: nil

  defp parse_unix_nanos(value) do
    case Integer.parse(value) do
      {nanos, ""} ->
        seconds = div(nanos, 1_000_000_000)
        microseconds = div(rem(nanos, 1_000_000_000), 1_000)

        seconds
        |> DateTime.from_unix!(:second)
        |> DateTime.add(microseconds, :microsecond)
        |> DateTime.truncate(:microsecond)

      _ ->
        nil
    end
  end

  defp artifact_metadata(conn) do
    %{
      "source" => "ios-fieldsurvey",
      "user_agent" => conn |> get_req_header("user-agent") |> List.first()
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
