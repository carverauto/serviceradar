defmodule ServiceRadarWebNG.Topology.Native do
  @moduledoc """
  Rust NIF bindings for God-View topology binary encoding.
  """

  @compile {:no_warn_unused_function, {:rustler_load_data, 2}}

  use Rustler,
    otp_app: :serviceradar_web_ng,
    crate: "god_view_nif",
    load_data: :rustler_load_data

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
  Encode God-View snapshot header + node/edge binary segments.
  """
  def encode_snapshot(
        _schema_version,
        _revision,
        _nodes,
        _edges,
        _root_bitmap_bytes,
        _affected_bitmap_bytes,
        _healthy_bitmap_bytes,
        _unknown_bitmap_bytes
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Evaluate causal states using the Rust/DeepCausality engine.
  """
  def evaluate_causal_states(_health_signals, _edges),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Build serialized Roaring bitmaps for each causal state bucket.
  """
  def build_roaring_bitmaps(_states),
    do: :erlang.nif_error(:nif_not_loaded)
end
