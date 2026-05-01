defmodule ServiceRadarWebNGWeb.PageController do
  use ServiceRadarWebNGWeb, :controller

  def home(conn, _params) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      redirect(conn, to: ~p"/dashboard")
    else
      redirect(conn, to: ~p"/users/log-in")
    end
  end

  def redirect_to_analytics(conn, _params) do
    redirect(conn, to: ~p"/analytics")
  end

  def redirect_to_wifi_map(conn, _params) do
    redirect(conn, to: ~p"/wifi-map")
  end

  def redirect_to_settings_profile(conn, _params) do
    redirect(conn, to: ~p"/settings/profile")
  end

  def redirect_to_settings_cluster(conn, _params) do
    redirect(conn, to: ~p"/settings/cluster")
  end

  def redirect_to_settings_cluster_node(conn, %{"node_name" => node_name}) do
    redirect(conn, to: ~p"/settings/cluster/nodes/#{node_name}")
  end

  def redirect_to_observability_flows(conn, params) do
    params = Map.drop(params, ["_format", "_mounts"])
    params = Map.put_new(params, "tab", "netflows")
    query = URI.encode_query(params)
    to = if query == "", do: "/observability?tab=netflows", else: "/observability?" <> query
    redirect(conn, to: to)
  end
end
