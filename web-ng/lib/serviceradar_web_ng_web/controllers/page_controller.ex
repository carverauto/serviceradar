defmodule ServiceRadarWebNGWeb.PageController do
  use ServiceRadarWebNGWeb, :controller

  def home(conn, _params) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      redirect(conn, to: ~p"/analytics")
    else
      redirect(conn, to: ~p"/users/log-in")
    end
  end

  def redirect_to_analytics(conn, _params) do
    redirect(conn, to: ~p"/analytics")
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

  def redirect_to_netflow(conn, params) do
    # Preserve SRQL query and any other URL params, but drop legacy tab marker.
    params =
      params
      |> Map.drop(["tab"])
      |> Map.reject(fn {_k, v} -> is_nil(v) or v == "" end)

    url =
      case params do
        %{} = p when map_size(p) > 0 -> "/netflow?" <> URI.encode_query(p)
        _ -> "/netflow"
      end

    redirect(conn, to: url)
  end
end
