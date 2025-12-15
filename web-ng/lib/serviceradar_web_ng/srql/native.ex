defmodule ServiceRadarWebNG.SRQL.Native do
  @moduledoc false

  use Rustler, otp_app: :serviceradar_web_ng, crate: "srql_nif"

  def translate(_query, _limit, _cursor, _direction, _mode),
    do: :erlang.nif_error(:nif_not_loaded)
end
