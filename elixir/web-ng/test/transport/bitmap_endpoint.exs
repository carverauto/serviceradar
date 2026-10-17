defmodule ServiceRadarWebNG.BitmapTransport.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :serviceradar_web_ng

  alias ServiceRadarWebNG.BitmapTransport.Socket

  socket "/plain", Socket,
    websocket: [compress: false],
    longpoll: false

  socket "/compressed", Socket,
    websocket: [compress: true],
    longpoll: false

  plug :not_found

  defp not_found(conn, _opts), do: Plug.Conn.send_resp(conn, 404, "not found")
end
