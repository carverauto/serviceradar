defmodule ServiceRadarWebNGWeb.PageController do
  use ServiceRadarWebNGWeb, :controller

  def home(conn, _params) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      redirect(conn, to: ~p"/analytics")
    else
      render(conn, :home)
    end
  end

  def redirect_to_analytics(conn, _params) do
    redirect(conn, to: ~p"/analytics")
  end
end
