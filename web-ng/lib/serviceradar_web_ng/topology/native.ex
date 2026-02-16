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

  @doc """
  Compute node layout coordinates from the Rust topology projection.
  Accepts node weights to anchor layered layout deterministically.
  """
  def layout_nodes_hypergraph(_node_count, _edges, _node_weights),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Enrich edge telemetry fields (flow_pps/flow_bps/capacity_bps/label) in Rust.
  Expects typed telemetry tuples; metadata JSON fallback is not supported.
  """
  def enrich_edges_telemetry(_edges, _interfaces, _pps_metrics, _bps_metrics),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Allocate a long-lived Rust runtime graph resource used by God-View.
  """
  def runtime_graph_new, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Replace runtime graph links in-place in the Rust resource.
  """
  def runtime_graph_replace_links(_graph_ref, _links),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Read runtime graph links from the Rust resource.
  """
  def runtime_graph_get_links(_graph_ref), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Ingest raw AGE topology rows into the Rust runtime graph resource.
  """
  def runtime_graph_ingest_rows(_graph_ref, _rows), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Resolve canonical indexed edges directly from the Rust runtime graph resource.
  """
  def runtime_graph_indexed_edges(_graph_ref, _node_ids, _allowed_edges),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Encode snapshot payload directly from the Rust runtime graph resource edge set.
  """
  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  def runtime_graph_encode_snapshot(
        _graph_ref,
        _schema_version,
        _revision,
        _node_ids,
        _nodes,
        _edge_telemetry,
        _root_bitmap_bytes,
        _affected_bitmap_bytes,
        _healthy_bitmap_bytes,
        _unknown_bitmap_bytes
      ),
      do: :erlang.nif_error(:nif_not_loaded)
end
