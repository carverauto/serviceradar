defmodule ServiceRadarWebNGWeb.Api.NorthboundActionCallbackController do
  @moduledoc false

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.Automation.Northbound.CommandResultHandler

  @token_header "x-serviceradar-callback-token"

  def create(conn, %{"job_id" => job_id} = params) do
    payload = Map.drop(params, ["job_id", "callback_token"])
    token = callback_token(conn, params)

    case CommandResultHandler.handle_callback_result(job_id, payload, token: token) do
      {:ok, status} ->
        json(conn, %{status: Atom.to_string(status), job_id: job_id})

      {:error, :target_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "job_not_found"})

      {:error, reason} when reason in [:invalid_callback_token, :callback_not_configured] ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "unauthorized"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "callback_rejected", reason: inspect(reason)})
    end
  end

  defp callback_token(conn, params) do
    conn
    |> get_req_header(@token_header)
    |> List.first()
    |> case do
      nil -> bearer_token(conn) || params["callback_token"]
      token -> token
    end
  end

  defp bearer_token(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> case do
      "Bearer " <> token -> token
      "bearer " <> token -> token
      _ -> nil
    end
  end
end
