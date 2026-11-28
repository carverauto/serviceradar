defmodule ServiceRadarWebNG.ClientIP do
  @moduledoc """
  Centralized client IP extraction.

  Parsing and proxy trust live in `Palisade.ClientIP`. This module only
  reads the application config that decides whether forwarding headers
  are trusted at all:

      config :serviceradar_web_ng, :client_ip,
        trust_x_forwarded_for: true,
        trusted_proxy_cidrs: ["10.0.0.0/8"]

  The default is not to trust `x-forwarded-for`. When the trusted list is
  so wide that every forwarded hop looks like a proxy (listing RFC1918
  wholesale does this to every LAN user), palisade returns the socket
  peer. In v1.4.56 that case raised, and every audited or rate-limited
  route was a 500.
  """

  alias Palisade.ClientIP, as: PalisadeClientIP

  @spec get(Plug.Conn.t()) :: String.t()
  def get(%Plug.Conn{} = conn) do
    conn
    |> PalisadeClientIP.from_conn(trusted_proxies: trusted_proxies())
    |> PalisadeClientIP.format()
  end

  defp trusted_proxies do
    config = Application.get_env(:serviceradar_web_ng, :client_ip, [])

    if Keyword.get(config, :trust_x_forwarded_for, false) do
      Keyword.get(config, :trusted_proxy_cidrs, [])
    else
      []
    end
  end
end
