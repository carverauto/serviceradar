defmodule ServiceRadarWebNG.SRQL.Native do
  @moduledoc false

  use Rustler, otp_app: :serviceradar_web_ng, crate: "srql_nif"

  def init(_database_url, _root_cert, _client_cert, _client_key, _pool_size),
    do: :erlang.nif_error(:nif_not_loaded)

  def query(_engine, _query, _limit, _cursor, _direction, _mode),
    do: :erlang.nif_error(:nif_not_loaded)
end
