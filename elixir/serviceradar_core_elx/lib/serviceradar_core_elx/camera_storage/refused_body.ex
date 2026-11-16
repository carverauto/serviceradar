defmodule ServiceRadarCoreElx.CameraStorage.RefusedBody do
  @moduledoc false
  # The storage listeners serve one request per connection and close after the
  # reply. Closing with a request body still in flight resets the connection, so
  # the client sees a transport error instead of the refusal and cannot tell a
  # permanent refusal from a lost connection. Before a 4xx refusal, a router
  # reads and drops the rest of the body: one bounded read at a time, never
  # kept and never written, up to `limit` bytes and the request deadline. Past
  # either, the refusal is answered and the connection closed as before.

  import Plug.Conn, only: [read_body: 2]

  @read_bytes 65_536

  @spec discard(Plug.Conn.t(), non_neg_integer(), integer()) :: Plug.Conn.t()
  def discard(conn, limit, deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 ->
        # One byte past the limit proves the body exceeds it, without reading on.
        case read(conn, min(@read_bytes, limit + 1), remaining) do
          {:more, bytes, next} when byte_size(bytes) <= limit ->
            discard(next, limit - byte_size(bytes), deadline)

          {_status, _bytes, next} ->
            next

          {:error, _reason} ->
            conn
        end

      _ ->
        conn
    end
  end

  # Bandit raises on a read timeout or malformed body. The refusal is still
  # answered on the connection as it stood before that read.
  defp read(conn, bytes, remaining) do
    read_body(conn, length: bytes, read_length: bytes, read_timeout: remaining)
  rescue
    _error in Bandit.HTTPError -> {:error, :body_unreadable}
  end
end
