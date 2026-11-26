defmodule ServiceRadarWebNGWeb.Plugs.ControlPlaneRuntimeAuth do
  @moduledoc """
  Authenticates requests to the cluster-only control-plane runtime listener.

  The caller credential is accepted only from
  `X-ServiceRadar-Control-Plane-Authorization`. The standard `Authorization`
  header remains reserved for Kubernetes API authentication when the control
  plane reaches this listener through the pod proxy.

  Media, storage entitlement, and media-worker routes each require a domain-separated
  installed credential and an exact deployment reference and purpose generation.
  """

  @behaviour Plug

  import Plug.Conn

  alias ServiceRadarWebNG.ControlPlaneRuntimeAccess

  @authorization_header "x-serviceradar-control-plane-authorization"
  @deployment_header "x-serviceradar-deployment-ref"
  @media_generation_header "x-serviceradar-media-generation"
  @entitlement_generation_header "x-serviceradar-entitlement-generation"
  @media_worker_generation_header "x-serviceradar-media-worker-generation"
  @vantage_worker_generation_header "x-serviceradar-vantage-worker-generation"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    # Plug.Router decodes segments before matching; authentication must select
    # the same purpose for encoded and literal spellings of a route.
    path = Enum.map(conn.path_info, &URI.decode/1)

    with ["Bearer " <> presented_token] <- get_req_header(conn, @authorization_header),
         {:ok, private_key, installation} <- authenticate(conn, path, presented_token) do
      put_private(conn, private_key, installation)
    else
      _invalid_authentication -> reject(conn)
    end
  end

  defp authenticate(conn, ["v1", "storage" | _rest], token) do
    with [reference] <- get_req_header(conn, @deployment_header),
         [generation] <- get_req_header(conn, @entitlement_generation_header),
         {:ok, installation} <-
           ControlPlaneRuntimeAccess.authenticate(:entitlements, token, {reference, generation}) do
      {:ok, :control_plane_entitlement_installation, installation}
    else
      _invalid_installation -> :error
    end
  end

  defp authenticate(conn, ["v1", "media", "workers" | _rest], token) do
    with [reference] <- get_req_header(conn, @deployment_header),
         {:ok, purposes, generation} <- extract_worker_purpose_headers(conn),
         {:ok, installation} <-
           authenticate_worker_purposes(purposes, token, reference, generation) do
      {:ok, :control_plane_media_worker_installation, installation}
    else
      _invalid_installation -> :error
    end
  end

  defp authenticate(conn, ["v1", scope | _rest], token) when scope == "media" or scope == "archive-bindings" do
    with [reference] <- get_req_header(conn, @deployment_header),
         [generation] <- get_req_header(conn, @media_generation_header),
         {:ok, installation} <-
           ControlPlaneRuntimeAccess.authenticate(:media, token, {reference, generation}) do
      {:ok, :control_plane_media_installation, installation}
    else
      _invalid_installation -> :error
    end
  end

  defp authenticate(_conn, _path, token) do
    case ControlPlaneRuntimeAccess.authenticate(:account, token, nil) do
      {:ok, installation} -> {:ok, :control_plane_media_installation, installation}
      :error -> :error
    end
  end

  defp authenticate_worker_purposes(purposes, token, reference, generation) do
    Enum.find_value(purposes, :error, fn purpose ->
      case ControlPlaneRuntimeAccess.authenticate(purpose, token, {reference, generation}) do
        {:ok, installation} -> {:ok, installation}
        :error -> false
      end
    end)
  end

  defp extract_worker_purpose_headers(conn) do
    vantage_headers = get_req_header(conn, @vantage_worker_generation_header)
    media_headers = get_req_header(conn, @media_worker_generation_header)

    case {vantage_headers, media_headers} do
      {[generation], []} -> {:ok, [:vantage_worker], generation}
      {[], [generation]} -> {:ok, [:media_worker, :vantage_worker], generation}
      _ -> :error
    end
  end

  defp reject(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{status: "unauthorized"}))
    |> halt()
  end
end
