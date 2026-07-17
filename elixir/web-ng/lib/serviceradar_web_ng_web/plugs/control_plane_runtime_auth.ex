defmodule ServiceRadarWebNGWeb.Plugs.ControlPlaneRuntimeAuth do
  @moduledoc """
  Authenticates requests to the cluster-only control-plane runtime listener.

  The caller credential is accepted only from
  `X-ServiceRadar-Control-Plane-Authorization`. The standard `Authorization`
  header remains reserved for Kubernetes API authentication when the control
  plane reaches this listener through the pod proxy.
  """

  @behaviour Plug

  import Plug.Conn

  @authorization_header "x-serviceradar-control-plane-authorization"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    expected_token = runtime_token()

    case get_req_header(conn, @authorization_header) do
      ["Bearer " <> presented_token] ->
        if valid_token?(expected_token, presented_token) do
          conn
        else
          reject(conn)
        end

      _headers ->
        reject(conn)
    end
  end

  defp runtime_token do
    :serviceradar_web_ng
    |> Application.get_env(:control_plane_runtime, [])
    |> Keyword.get(:token)
  end

  defp valid_token?(expected_token, presented_token)
       when is_binary(expected_token) and byte_size(expected_token) >= 32 and is_binary(presented_token) and
              byte_size(presented_token) <= 512 do
    expected_digest = :crypto.hash(:sha256, expected_token)
    presented_digest = :crypto.hash(:sha256, presented_token)

    Plug.Crypto.secure_compare(expected_digest, presented_digest)
  end

  defp valid_token?(_expected_token, _presented_token), do: false

  defp reject(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{status: "unauthorized"}))
    |> halt()
  end
end
