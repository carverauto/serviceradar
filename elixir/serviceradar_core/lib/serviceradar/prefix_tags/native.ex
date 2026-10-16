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
  def prepare_catalog(_snapshot, _timeout_ms), do: :erlang.nif_error(:nif_not_loaded)
  def release_catalog(_snapshot), do: :erlang.nif_error(:nif_not_loaded)
  def catalog_status(_snapshot), do: :erlang.nif_error(:nif_not_loaded)

  def label_page(_snapshot, _after_label, _limit, _timeout_ms),
    do: :erlang.nif_error(:nif_not_loaded)

  def label_ranges(_snapshot, _label, _max_ranges, _max_bytes, _timeout_ms),
    do: :erlang.nif_error(:nif_not_loaded)
end
