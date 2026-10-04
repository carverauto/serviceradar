defmodule ServiceRadarWebNGWeb.Api.RawBodyReader do
  @moduledoc """
  The endpoint body reader that keeps the exact request bytes for the routes
  whose signatures are computed over them.

  `Plug.Parsers` consumes the body and hands the controller a decoded map, so a
  verifier that re-encodes that map is comparing an HMAC against bytes the
  client never sent - key order, whitespace, and number formatting all differ.
  This reader buffers the untouched bytes on the way past so
  `raw_body/1` can hand back what was actually posted.

  ## Buffering is opt-in, by path prefix

  Retaining every request body in `conn.private` would double the memory cost of
  every upload on the server for the benefit of a handful of routes, so a prefix
  has to be registered in `@callback_prefixes` to be buffered. Two are registered
  today:

    * `/api/northbound/action-callbacks/` - the northbound command-result
      callback, which signs `<timestamp>.<raw_body>` with HMAC-SHA256
      (`automation/northbound/command_result_handler.ex`).
    * `/api/notifications/callbacks/` - notification provider callbacks
      (design D7 Phase 4: Slack interactive components, PagerDuty webhooks,
      generic webhook acknowledgement), which sign bytes the same way.

  The notification prefix is registered ahead of the routes that use it on
  purpose. An unregistered prefix does not fail loudly: `raw_body/1` returns
  `""`, the verifier falls back to a re-encoded body, and signatures break for
  exactly the providers that sign bytes - a silent verification failure
  discovered in production rather than in CI.

  Adding a prefix here is the whole registration; there is no second list to
  keep in step.
  """

  alias ServiceRadarWebNGWeb.NotificationCallbackBody

  @callback_prefixes [
    "/api/northbound/action-callbacks/",
    "/api/notifications/callbacks/"
  ]

  @raw_body_private_key :serviceradar_raw_body_chunks
  @notification_body_limit NotificationCallbackBody.limit()

  @doc "The path prefixes whose request bodies are buffered verbatim."
  @spec callback_prefixes() :: [String.t()]
  def callback_prefixes, do: @callback_prefixes

  @doc """
  Whether a request path is buffered. Exposed so a route can be proven covered
  by a test rather than by reading the prefix list.
  """
  @spec buffered?(term()) :: boolean()
  def buffered?(request_path) when is_binary(request_path) do
    String.starts_with?(request_path, @callback_prefixes)
  end

  def buffered?(_request_path), do: false

  def read_body(conn, opts) do
    opts =
      if NotificationCallbackBody.callback?(conn) do
        opts
        |> Keyword.update(:length, @notification_body_limit, &min(&1, @notification_body_limit))
        |> Keyword.update(:read_length, 65_536, &min(&1, 65_536))
      else
        opts
      end

    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, maybe_store_raw_body(conn, body)}
      {:more, body, conn} -> {:more, body, maybe_store_raw_body(conn, body)}
      other -> other
    end
  end

  def raw_body(conn) do
    conn.private
    |> Map.get(@raw_body_private_key, [])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp maybe_store_raw_body(%{request_path: request_path} = conn, body)
       when is_binary(request_path) and is_binary(body) do
    notification_callback? = NotificationCallbackBody.callback?(conn)

    if notification_callback? or buffered?(request_path) do
      chunks = [body | Map.get(conn.private, @raw_body_private_key, [])]

      if notification_callback? and IO.iodata_length(chunks) > @notification_body_limit do
        raise Plug.Parsers.RequestTooLargeError
      end

      Plug.Conn.put_private(conn, @raw_body_private_key, chunks)
    else
      conn
    end
  end

  defp maybe_store_raw_body(conn, _body), do: conn
end
