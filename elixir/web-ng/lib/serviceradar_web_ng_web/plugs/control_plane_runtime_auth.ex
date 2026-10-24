defmodule ServiceRadarWebNGWeb.Plugs.ControlPlaneRuntimeAuth do
  @moduledoc """
  Authenticates requests to the cluster-only control-plane runtime listener.

  The caller credential is accepted only from
  `X-ServiceRadar-Control-Plane-Authorization`. The standard `Authorization`
  header remains reserved for Kubernetes API authentication when the control
  plane reaches this listener through the pod proxy.

  Media routes require a separate installed credential and an exact deployment
  reference/generation. The installation describes this process, not a tenant
  routing key or permission to perform provider operations.
  """

  @behaviour Plug

  import Plug.Conn

  alias ServiceRadarWebNG.ControlPlaneRuntimeAccess

  @authorization_header "x-serviceradar-control-plane-authorization"
  @deployment_header "x-serviceradar-deployment-ref"
  @generation_header "x-serviceradar-media-generation"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    # Plug.Router decodes segments before matching; authentication must select
    # the same purpose for encoded and literal spellings of a route.
    path = Enum.map(conn.path_info, &URI.decode/1)

    with ["Bearer " <> presented_token] <- get_req_header(conn, @authorization_header),
         {:ok, installation} <- authenticate(conn, path, presented_token) do
      put_private(conn, :control_plane_media_installation, installation)
    else
      _invalid_authentication -> reject(conn)
    end
  end

  defp authenticate(conn, ["v1", scope | _rest], token) when scope == "media" or scope == "archive-bindings" do
    with [reference] <- get_req_header(conn, @deployment_header),
         [generation] <- get_req_header(conn, @generation_header) do
      ControlPlaneRuntimeAccess.authenticate(:media, token, {reference, generation})
    else
      _invalid_installation -> :error
    end
  end

  defp authenticate(_conn, _path, token), do: ControlPlaneRuntimeAccess.authenticate(:account, token, nil)

  defp reject(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{status: "unauthorized"}))
    |> halt()
  end
end
