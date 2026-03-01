defmodule ServiceRadarWebNG.Api.TopologyController do
  @moduledoc """
  JSON API controller for topology analysis helpers.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadar.NetworkDiscovery.RouteAnalyzer
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.RBAC

  action_fallback ServiceRadarWebNG.Api.FallbackController

  @doc """
  POST /api/admin/topology/route-analysis

  Body:
    - source_device_id (string, required)
    - destination_ip (string, required)
    - routes_by_device (map, required)
    - max_hops (integer, optional)
  """
  def route_analysis(conn, params) do
    with :ok <- require_authenticated(conn),
         :ok <- require_permission(conn, "settings.networks.manage"),
         {:ok, request} <- normalize_route_analysis_request(params),
         {:ok, result} <-
           RouteAnalyzer.analyze(
             request.routes_by_device,
             request.source_device_id,
             request.destination_ip,
             max_hops: request.max_hops
           ) do
      json(conn, %{result: route_analysis_json(result)})
    else
      {:error, :invalid_request, message} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: message})

      {:error, :invalid_ipv4} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "invalid_request",
          message: "destination_ip must be a valid IPv4 address"
        })

      {:error, :invalid_arguments} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_request", message: "invalid route analysis arguments"})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "route_analysis_failed", reason: inspect(reason)})
    end
  end

  defp normalize_route_analysis_request(params) when is_map(params) do
    source_device_id =
      params
      |> Map.get("source_device_id", Map.get(params, "start_device_id"))
      |> normalize_non_empty_string()

    destination_ip = params |> Map.get("destination_ip") |> normalize_non_empty_string()
    routes_by_device = params |> Map.get("routes_by_device") |> normalize_routes_by_device()

    cond do
      is_nil(source_device_id) ->
        {:error, :invalid_request, "source_device_id is required"}

      is_nil(destination_ip) ->
        {:error, :invalid_request, "destination_ip is required"}

      is_nil(routes_by_device) ->
        {:error, :invalid_request, "routes_by_device map is required"}

      true ->
        {:ok,
         %{
           source_device_id: source_device_id,
           destination_ip: destination_ip,
           routes_by_device: routes_by_device,
           max_hops: normalize_max_hops(Map.get(params, "max_hops"))
         }}
    end
  end

  defp normalize_route_analysis_request(_),
    do: {:error, :invalid_request, "request body is required"}

  defp normalize_routes_by_device(value) when is_map(value), do: value
  defp normalize_routes_by_device(_), do: nil

  defp normalize_non_empty_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_non_empty_string(_), do: nil

  defp normalize_max_hops(value) when is_integer(value) and value > 0, do: value

  defp normalize_max_hops(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> 16
    end
  end

  defp normalize_max_hops(_), do: 16

  defp route_analysis_json(result) when is_map(result) do
    result
    |> Map.update(:status, "unknown", &to_string/1)
    |> Map.update(:hops, [], fn hops -> Enum.map(hops, &hop_json/1) end)
  end

  defp route_analysis_json(_), do: %{}

  defp hop_json(hop) when is_map(hop) do
    hop
    |> Map.update(:ecmp_branches, [], fn branches ->
      Enum.map(branches, fn branch ->
        %{
          target_device_id:
            Map.get(branch, :target_device_id) || Map.get(branch, "target_device_id"),
          next_hop_ip: Map.get(branch, :next_hop_ip) || Map.get(branch, "next_hop_ip"),
          interface: Map.get(branch, :interface) || Map.get(branch, "interface")
        }
      end)
    end)
  end

  defp hop_json(_), do: %{}

  defp require_authenticated(conn) do
    case conn.assigns[:current_scope] do
      %Scope{user: user} when not is_nil(user) -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  defp require_permission(conn, permission) do
    scope = conn.assigns[:current_scope]
    if RBAC.can?(scope, permission), do: :ok, else: {:error, :forbidden}
  end
end
