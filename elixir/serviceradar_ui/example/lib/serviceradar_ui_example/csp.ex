defmodule ServiceRadarUIExample.CSP do
  @moduledoc false

  @behaviour Plug

  @policy "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; font-src 'self'; base-uri 'none'; form-action 'self'"

  def policy, do: @policy

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    Plug.Conn.put_resp_header(conn, "content-security-policy", @policy)
  end
end
