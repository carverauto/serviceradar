defmodule ServiceRadar.PrefixTags.Native do
  @moduledoc "Rustler resource boundary for prefix snapshots. Use NativeEngine for lookups."

  use Rustler,
    otp_app: :serviceradar_core,
    crate: "prefix_tags_nif",
    # Scope unwinding to this Cargo invocation, including its dependencies.
    # The native crate refuses to compile with panic=abort.
    env: [{"CARGO_PROFILE_RELEASE_PANIC", "unwind"}]

  def new_builder, do: :erlang.nif_error(:nif_not_loaded)
  def append(_builder, _rows), do: :erlang.nif_error(:nif_not_loaded)
  def finish(_builder), do: :erlang.nif_error(:nif_not_loaded)
  def lookup(_snapshot, _address), do: :erlang.nif_error(:nif_not_loaded)
  def stats(_snapshot), do: :erlang.nif_error(:nif_not_loaded)
end
