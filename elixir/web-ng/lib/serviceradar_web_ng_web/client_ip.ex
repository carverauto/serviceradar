defmodule ServiceRadarWebNGWeb.ClientIP do
  @moduledoc """
  Web-facing wrapper for centralized client IP extraction.
  """

  alias ServiceRadarWebNG.ClientIP

  @spec get(Plug.Conn.t()) :: String.t()
  def get(%Plug.Conn{} = conn) do
    ClientIP.get(conn)
  end
end
