defmodule ServiceRadarWebNG.Topology.Native do
  @moduledoc """
  Rust NIF bindings for God-View topology binary encoding.
  """

  use Rustler,
    otp_app: :serviceradar_web_ng,
    crate: "god_view_nif",
    load_data: :rustler_load_data,
    # Mix builds path dependencies in :prod, so Rustler compiles this crate in
    # release mode, where the workspace profile sets panic = "abort". Scope
    # unwinding to this Cargo invocation, as the Bazel build does with
    # -Cpanic=unwind: the crate refuses to compile with panic=abort.
    env: [{"CARGO_PROFILE_RELEASE_PANIC", "unwind"}]

  @compile {:no_warn_unused_function, {:rustler_load_data, 2}}

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
  def encode_snapshot(_payload), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Encode schema-3 geometry with at most 128 nodes and 256 KiB; tiles allow 512 edges, details 256."
  def encode_scene(_payload, _metadata), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Evaluate causal states using the Rust/DeepCausality engine.
  """
  def evaluate_causal_states(_health_signals, _edges), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Evaluate causal states with per-node causal reason metadata.
  """
  def evaluate_causal_states_with_reasons(_health_signals, _edges), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Build serialized Roaring bitmaps for each causal state bucket.
  """
  def build_roaring_bitmaps(_states), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Compute node layout coordinates from the Rust topology projection.
  Accepts node weights to anchor layered layout deterministically.
  """
  def layout_nodes_hypergraph(_node_count, _edges, _node_weights), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Enrich edge telemetry fields (flow_pps/flow_bps/capacity_bps/label) in Rust.
  Expects typed telemetry tuples; metadata JSON fallback is not supported.
  """
  def enrich_edges_telemetry(_edges, _interfaces, _pps_metrics, _bps_metrics), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Allocate a long-lived Rust runtime graph resource used by God-View.
  """
  def runtime_graph_new, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Replace runtime graph links in-place in the Rust resource.
  """
  def runtime_graph_replace_links(_graph_ref, _links), do: :erlang.nif_error(:nif_not_loaded)

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
  def runtime_graph_indexed_edges(_graph_ref, _node_ids, _allowed_edges), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Encode snapshot payload directly from the Rust runtime graph resource edge set.
  """
  def runtime_graph_encode_snapshot(_payload), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Create an unpublished index. Epochs are 16-byte binaries; kind is :device or :interface."
  def bitmap_index_new(_dictionary_epoch, _index_epoch, _kind, _supported_facets), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Atomically replace up to 500 current rows {ordinal, live?, [{facet, value}]} at the expected revision."
  def bitmap_index_publish(_index, _expected_revision, _source_revision, _rows, _ready),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Read admission/memory/freshness diagnostics and reap expired query pins."
  def bitmap_index_status(_index), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Coalesce at most 500 nonzero ordinals; a rescan request advances the reconciliation fence."
  def bitmap_index_mark_dirty(_index, _ordinals, _request_rescan), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Take up to 500 sorted ordinals before reading their source rows.
  Requeue them when that publish fails, unless the index already folded the queue into a rescan.
  """
  def bitmap_index_take_dirty(_index, _limit), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Acknowledge a completed full keyset pass only at the generation observed before that pass."
  def bitmap_index_acknowledge_reconcile(_index, _observed_generation), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Evaluate a typed postfix expression and pin its exact revision for 30 seconds.
  Instructions are {opcode, facet, value_binary, arity}: exact=0, all=1, any=2,
  except=3, value-prefix=4, tag-key-prefix=5, paired-tag-exact=6,
  paired-tag-prefix=7, numeric CIDR=8, packed address ranges=9.
  Boolean operator strings are empty. Current RBAC admission and
  delivery checks remain the caller's responsibility; authority is its fingerprint.
  """
  def bitmap_index_query(_index, _dictionary_epoch, _index_epoch, _kind, _authority, _program, _timeout_ms),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Stage at most 500 scalar rows; complete address pages publish atomically at finish."
  def bitmap_index_begin_publish(_index, _expected_revision, _source_revision, _rows, _ready),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Add at most 500 {ordinal, packed IPv4/IPv6} pairs and 500 completed device ordinals."
  def bitmap_publish_addresses(_stage, _addresses, _completed), do: :erlang.nif_error(:nif_not_loaded)
  def bitmap_publish_ip_unavailable(_stage), do: :erlang.nif_error(:nif_not_loaded)
  def bitmap_publish_abort(_stage), do: :erlang.nif_error(:nif_not_loaded)
  def bitmap_index_finish_publish(_index, _stage), do: :erlang.nif_error(:nif_not_loaded)

  def bitmap_query_page(_query, _authority, _after, _limit, _timeout_ms), do: :erlang.nif_error(:nif_not_loaded)
  def bitmap_query_facets(_query, _authority, _facets, _timeout_ms), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Bounded lexical discovery over current canonical facet values."
  def bitmap_query_values(_query, _authority, _facet, _search, _after, _limit, _timeout_ms),
    do: :erlang.nif_error(:nif_not_loaded)

  def bitmap_query_intersection_count(
        _query,
        _authority,
        _dictionary_epoch,
        _index_epoch,
        _kind,
        _portable_bitmap,
        _timeout_ms
      ), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Project at most 128 leaf/aggregate selectors into typed row columns from one pinned revision."
  def bitmap_query_row_overlay(_query, _authority, _dictionary_epoch, _index_epoch, _kind, _rows, _timeout_ms),
    do: :erlang.nif_error(:nif_not_loaded)

  def bitmap_index_close(_index), do: :erlang.nif_error(:nif_not_loaded)

  def bitmap_query_close(_query), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Decode Apache Arrow IPC frames into Elixir maps.
  """
  def decode_arrow_payload(_binary), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Decode FieldSurvey Sidekick raw RF Apache Arrow IPC frames into Elixir maps.
  """
  def decode_fieldsurvey_rf_payload(_binary), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Decode FieldSurvey iOS pose Apache Arrow IPC frames into Elixir maps.
  """
  def decode_fieldsurvey_pose_payload(_binary), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Decode FieldSurvey Sidekick SDR spectrum Apache Arrow IPC frames into Elixir maps.
  """
  def decode_fieldsurvey_spectrum_payload(_binary), do: :erlang.nif_error(:nif_not_loaded)
end
