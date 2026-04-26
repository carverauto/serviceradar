defmodule ServiceRadarWebNGWeb.Api.FieldSurveyStreamController do
  use ServiceRadarWebNGWeb, :controller

  require Logger

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
        Logger.info("Upgrading FieldSurvey #{stream_type} Arrow stream for user #{user_id}, session: #{session_id}")

        conn
        |> WebSockAdapter.upgrade(
          ServiceRadarWebNGWeb.Channels.FieldSurveyArrowStreamHandler,
          [session_id: session_id, user_id: user_id, stream_type: stream_type],
          timeout: 60_000
        )
        |> halt()

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{ok: false, error: "unauthorized"})
    end
  end
end
