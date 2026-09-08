defmodule ServiceRadarWebNGWeb.ControlPlaneRuntimeRouter do
  @moduledoc """
  Cluster-only HTTP contract used by the hosted control plane.

  This router is served by a dedicated Bandit listener that is intentionally
  absent from the public Service and Gateway routes.
  """

  use Plug.Router

  alias ServiceRadarWebNGWeb.Auth.PasswordResetDelivery
  alias ServiceRadarWebNGWeb.Plugs.ControlPlaneRuntimeAuth

  require Logger

  plug Plug.RequestId
  plug ControlPlaneRuntimeAuth

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  plug :match
  plug :dispatch

  post "/v1/password-reset" do
    case conn.body_params do
      %{"email" => email} when is_binary(email) ->
        deliver_password_reset(conn, email)

      _params ->
        respond(conn, 400, "invalid_request")
    end
  end

  match _ do
    respond(conn, 404, "not_found")
  end

  defp deliver_password_reset(conn, email) do
    result = apply(password_reset_delivery(), :deliver, [email, []])

    case result do
      {:ok, :smtp_accepted} ->
        respond(conn, 202, "smtp_accepted")

      {:error, :invalid_request} ->
        respond(conn, 400, "invalid_request")

      {:error, reason} when reason in [:request_rejected, :smtp_delivery_failed] ->
        Logger.warning("control-plane password reset submission failed reason_type=#{reason}")
        respond(conn, 502, "delivery_failed")

      _other ->
        Logger.warning("control-plane password reset submission failed reason_type=unexpected_response")
        respond(conn, 502, "delivery_failed")
    end
  rescue
    _exception ->
      Logger.warning("control-plane password reset submission failed reason_type=internal_error")
      respond(conn, 502, "delivery_failed")
  end

  defp password_reset_delivery do
    Application.get_env(
      :serviceradar_web_ng,
      :control_plane_password_reset_delivery,
      PasswordResetDelivery
    )
  end

  defp respond(conn, status, response_status) do
    body = Jason.encode!(%{status: response_status})

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end
end
