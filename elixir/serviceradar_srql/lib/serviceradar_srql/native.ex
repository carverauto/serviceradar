defmodule ServiceRadarSRQL.Native do
  @moduledoc """
  Rust NIF bindings for SRQL parsing and translation.
  """
  use Rustler,
    otp_app: :serviceradar_srql,
    crate: "srql_nif",
    load_data: :rustler_load_data,
    # Mix builds path dependencies in :prod, so Rustler compiles this crate in
    # release mode, where the workspace profile sets panic = "abort". Scope
    # unwinding to this Cargo invocation, as the Bazel build does with
    # -Cpanic=unwind: the crate refuses to compile with panic=abort.
    env: [{"CARGO_PROFILE_RELEASE_PANIC", "unwind"}]

  @compile {:no_warn_unused_function, {:rustler_load_data, 2}}

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
  Translate an SRQL query to SQL and return the result as JSON, with no
  permitted-signal set.

  Equivalent to `translate/6` with `nil`, so entities that require a trusted
  signal set (`in:otel_services`) are rejected as forbidden.
  """
  def translate(query, limit, cursor, direction, mode), do: translate(query, limit, cursor, direction, mode, nil)

  @doc """
  Translate an SRQL query to SQL and return the result as JSON.

  `permitted_signals` is the caller's trusted list of viewable OTel signals
  (`"logs"`, `"traces"`, `"metrics"`), computed by its access gate and never
  derived from the query string, or `nil` when no set applies. A query that
  needs the set and lacks it, or asks for a signal outside it, returns
  `{:error, "forbidden: " <> reason}`.
  """
  def translate(_query, _limit, _cursor, _direction, _mode, _permitted_signals), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Compile a bounded JSON request of exact device/interface pairs to current
  IF-MIB rates. Backend mode comes from the trusted dataset reader routing.
  """
  def translate_interface_rates(_request, _mode), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Parse an SRQL query and return the AST as JSON.
  This allows consuming the structured query without re-parsing in Elixir.
  """
  def parse_ast(_query), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Encode normalized SRQL row JSON into an Apache Arrow IPC file payload.
  """
  def encode_arrow_json(_columns, _rows_json), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Decode an Arancini Cap'n Proto update payload into JSON.
  """
  def decode_arancini_update_capnp(_payload), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def encode_arancini_update_capnp(_json_payload), do: :erlang.nif_error(:nif_not_loaded)
end
