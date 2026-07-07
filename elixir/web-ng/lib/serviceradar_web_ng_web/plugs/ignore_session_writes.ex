defmodule ServiceRadarWebNGWeb.Plugs.IgnoreSessionWrites do
  @moduledoc """
  Suppresses session-cookie writes for binary / websocket-upgrade endpoints
  (the `:browser_raw_auth` pipeline).

  Those endpoints authenticate from the session cookie, and
  `UserAuth.fetch_current_scope_for_user/2` runs a sliding-session refresh
  (`put_session/3` + `configure_session/2`) on every authenticated request. That
  marks the session dirty and registers a `Plug.Session` `before_send` callback
  that writes the `set-cookie` header.

  For a websocket upgrade that callback is fatal. `WebSockAdapter.upgrade/4`
  calls `Plug.Conn.upgrade_adapter/3`, which runs `run_before_send(conn, :upgraded)`
  before handing the socket to the adapter. Plug 1.20's cookie writer
  (`Plug.Conn.update_cookies/2`) raises `Plug.Conn.AlreadySentError` for any conn
  whose state is not in `@unsent` (`:unset`/`:set`/`:set_chunked`/`:set_file`) —
  and `:upgraded` is not in that set. The `GET .../stream` request then returns
  HTTP 500 and the browser's WebCodecs stream never connects, even though the
  relay session itself is active and media is flowing upstream.

  A 101 upgrade response has nowhere useful to persist a rotated session cookie,
  so this plug tells `Plug.Session` to ignore session mutations for the request.
  The browser keeps its existing (still-valid) session cookie; the sliding
  refresh resumes on the next ordinary request.
  """

  @behaviour Plug

  import Plug.Conn, only: [configure_session: 2]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if session_fetched?(conn) do
      configure_session(conn, ignore: true)
    else
      conn
    end
  end

  # `configure_session/2` reads the session (`get_session/1`), which raises when
  # no session middleware ran for the request. Guard so the plug is inert if it
  # is ever composed into a pipeline without `fetch_session`.
  defp session_fetched?(conn), do: Map.has_key?(conn.private, :plug_session_fetch)
end
