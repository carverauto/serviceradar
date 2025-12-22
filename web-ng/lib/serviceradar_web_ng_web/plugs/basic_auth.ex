defmodule ServiceRadarWebNGWeb.Plugs.BasicAuth do
  @moduledoc false

  import Plug.Conn

  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    case Application.get_env(:serviceradar_web_ng, :admin_basic_auth) do
      %{username: username, password: password}
      when is_binary(username) and is_binary(password) ->
        Plug.BasicAuth.basic_auth(conn,
          username: username,
          password: password,
          realm: "ServiceRadar Admin"
        )

      _ ->
        Logger.warning("Admin basic auth is not configured")

        conn
        |> send_resp(:service_unavailable, "Admin basic auth not configured")
        |> halt()
    end
  end
end
