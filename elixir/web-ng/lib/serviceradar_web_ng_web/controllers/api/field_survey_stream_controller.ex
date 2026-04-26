defmodule ServiceRadarWebNGWeb.Api.FieldSurveyStreamController do
  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.FieldSurveySessionOwnership

  require Logger

  @max_frame_size 8 * 1024 * 1024

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
end
