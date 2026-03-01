defmodule ServiceRadarSRQL.Native do
  @moduledoc """
  Rust NIF bindings for SRQL parsing and translation.
  """
  @compile {:no_warn_unused_function, {:rustler_load_data, 2}}

  use Rustler,
    otp_app: :serviceradar_srql,
    crate: "srql_nif",
    load_data: :rustler_load_data

  # Rustler `load_data` must be a named function so the macro can quote it.
  @doc false
  def rustler_load_data(_env, _priv) do
    %{
      tmp_dir:
        System.get_env("RUSTLER_TMPDIR") ||
          System.get_env("RUSTLER_TEMP_DIR") ||
          System.tmp_dir!()
    }
  end

  @doc """
  Translate an SRQL query to SQL and return the result as JSON.
  """
  def translate(_query, _limit, _cursor, _direction, _mode),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Parse an SRQL query and return the AST as JSON.
  This allows consuming the structured query without re-parsing in Elixir.
  """
  def parse_ast(_query),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Decode an Arancini Cap'n Proto update payload into JSON.
  """
  def decode_arancini_update_capnp(_payload),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def encode_arancini_update_capnp(_json_payload),
    do: :erlang.nif_error(:nif_not_loaded)
end
