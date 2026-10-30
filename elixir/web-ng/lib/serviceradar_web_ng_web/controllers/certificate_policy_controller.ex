defmodule ServiceRadarWebNGWeb.CertificatePolicyController do
  use ServiceRadarWebNGWeb, :controller

  def show(conn, _params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case ServiceRadarWebNG.CertificatePolicyCache.fetch() do
      {:ok, envelope} -> json(conn, envelope)
      {:error, _} -> conn |> put_status(:service_unavailable) |> json(%{error: "certificate_policy_unavailable"})
    end
  end
end
