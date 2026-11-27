defmodule Palisade.Plug.RemoteIP do
  @moduledoc """
  Replaces `conn.remote_ip` with the client address resolved by
  `Palisade.ClientIP`.

  The socket peer the request actually arrived from is kept in
  `conn.private[:palisade_peer_ip]`. Later calls to
  `Palisade.ClientIP.from_conn/2` see that key and return `conn.remote_ip`
  without reading the forwarding header again.

  Takes the same options as `Palisade.ClientIP`, validated once at init:

      plug Palisade.Plug.RemoteIP, trusted_proxies: ["10.0.0.0/8"]

  Place it in the endpoint before anything that reads `conn.remote_ip`
  (logging, rate limiting, sessions bound to an address).
  """

  @behaviour Plug

  alias Palisade.ClientIP

  @impl Plug
  def init(opts), do: ClientIP.new(opts)

  @impl Plug
  def call(%Plug.Conn{} = conn, %ClientIP{} = config) do
    key = ClientIP.peer_private_key()

    if Map.has_key?(conn.private, key) do
      conn
    else
      client = ClientIP.from_conn(conn, config)

      %{conn | remote_ip: client}
      |> Plug.Conn.put_private(key, conn.remote_ip)
    end
  end
end
