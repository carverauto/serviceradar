defmodule ServiceRadarWebNG.SRQL.Native do
  @moduledoc false

  use Rustler,
    otp_app: :serviceradar_web_ng,
    crate: "srql_nif",
    load_data: fn ->
      # Prefer Bazel-provided tmpdir if present to keep path deps resolvable.
      %{
        tmp_dir: System.get_env("RUSTLER_TMPDIR") ||
          System.get_env("RUSTLER_TEMP_DIR") ||
          System.tmp_dir!()
      }
    end

  def translate(_query, _limit, _cursor, _direction, _mode),
    do: :erlang.nif_error(:nif_not_loaded)
end
