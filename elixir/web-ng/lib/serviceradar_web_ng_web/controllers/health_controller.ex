defmodule ServiceRadarWebNGWeb.HealthController do
  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNG.Repo

  def live(conn, _params) do
    send_resp(conn, 200, "ok")
  end

  def ready(conn, _params) do
    case Repo.query("SELECT 1") do
      {:ok, _result} -> send_resp(conn, 200, "ready")
      {:error, _reason} -> send_resp(conn, 503, "not ready")
    end
  end
end
