defmodule ServiceRadar.Dgraph.Native do
  @moduledoc """
  Rustler NIF bindings for `dgraph_topology`.

  The BEAM-visible seam for Dgraph. Typed topology reads and writes cross the ABI
  as `NifMap` structs; the read-only DQL hatch returns JSON. Callers should use
  `ServiceRadar.Dgraph`, which supplies the connection URL and deadline, refuses
  mutations before they reach this module, and waits for the reply.

  Every operation is asynchronous and runs on a normal scheduler: it returns
  `{:ok, ref, handle}` at once (or `{:error, reason}` for input rejected without
  contacting Dgraph), and the result arrives later as
  `{:dgraph_nif_reply, ref, result, {kind, queue_wait_us, elapsed_us}}`. The
  last argument is the call deadline in milliseconds. See
  `ServiceRadar.Dgraph.Call` for the reply protocol and `cancel/1`.
  """

  use Rustler,
    otp_app: :serviceradar_core,
    crate: "dgraph_nif"

  @type url :: String.t()
  @type deadline_ms :: non_neg_integer()
  @type submission :: {:ok, reference(), reference()} | {:error, String.t()}

  @doc "Cancel an in-flight call: `:cancelled` (no reply will arrive) or `:replying`."
  @spec cancel(reference()) :: :cancelled | :replying
  def cancel(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @spec upsert_device(url(), map(), deadline_ms()) :: submission()
  def upsert_device(_url, _device, _deadline_ms), do: :erlang.nif_error(:nif_not_loaded)

  @spec upsert_interface(url(), map(), deadline_ms()) :: submission()
  def upsert_interface(_url, _iface, _deadline_ms), do: :erlang.nif_error(:nif_not_loaded)

  @spec upsert_prefix(url(), map(), deadline_ms()) :: submission()
  def upsert_prefix(_url, _prefix, _deadline_ms), do: :erlang.nif_error(:nif_not_loaded)

  @spec attach_prefix(url(), String.t(), String.t(), deadline_ms()) :: submission()
  def attach_prefix(_url, _iface_key, _cidr, _deadline_ms), do: :erlang.nif_error(:nif_not_loaded)

  @spec upsert_change(url(), map(), deadline_ms()) :: submission()
  def upsert_change(_url, _change, _deadline_ms), do: :erlang.nif_error(:nif_not_loaded)

  @spec upsert_hop(url(), map(), deadline_ms()) :: submission()
  def upsert_hop(_url, _hop, _deadline_ms), do: :erlang.nif_error(:nif_not_loaded)

  @spec upsert_edge(url(), map(), deadline_ms()) :: submission()
  def upsert_edge(_url, _edge, _deadline_ms), do: :erlang.nif_error(:nif_not_loaded)

  @spec retire_hosted_edge(url(), String.t(), String.t(), String.t(), deadline_ms()) ::
          submission()
  def retire_hosted_edge(_url, _source, _target, _observed_at, _deadline_ms),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec replace_hosted_edge(url(), map(), deadline_ms()) :: submission()
  def replace_hosted_edge(_url, _edge, _deadline_ms), do: :erlang.nif_error(:nif_not_loaded)

  @spec upsert_canonical_edge(url(), map(), deadline_ms()) :: submission()
  def upsert_canonical_edge(_url, _edge, _deadline_ms), do: :erlang.nif_error(:nif_not_loaded)

  @spec update_canonical_edge_telemetry(url(), map(), deadline_ms()) :: submission()
  def update_canonical_edge_telemetry(_url, _edge, _deadline_ms),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec upsert_mtr_path(url(), map(), deadline_ms()) :: submission()
  def upsert_mtr_path(_url, _edge, _deadline_ms), do: :erlang.nif_error(:nif_not_loaded)

  @spec prune_stale(url(), String.t(), [String.t()], deadline_ms()) :: submission()
  def prune_stale(_url, _cutoff, _kinds, _deadline_ms), do: :erlang.nif_error(:nif_not_loaded)

  @spec rebuild_canonical(url(), [map()], deadline_ms()) :: submission()
  def rebuild_canonical(_url, _edges, _deadline_ms), do: :erlang.nif_error(:nif_not_loaded)

  @spec query_canonical_edges(url(), deadline_ms()) :: submission()
  def query_canonical_edges(_url, _deadline_ms), do: :erlang.nif_error(:nif_not_loaded)

  @spec query_canonical_graph(url(), deadline_ms()) :: submission()
  def query_canonical_graph(_url, _deadline_ms), do: :erlang.nif_error(:nif_not_loaded)

  @spec downstream_of(url(), [String.t()], [String.t()], deadline_ms()) :: submission()
  def downstream_of(_url, _from_ids, _to_ids, _deadline_ms),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec query_neighbourhood(url(), String.t(), deadline_ms()) :: submission()
  def query_neighbourhood(_url, _device_id, _deadline_ms), do: :erlang.nif_error(:nif_not_loaded)

  @spec query_dql(url(), String.t(), deadline_ms()) :: submission()
  def query_dql(_url, _dql, _deadline_ms), do: :erlang.nif_error(:nif_not_loaded)
end
