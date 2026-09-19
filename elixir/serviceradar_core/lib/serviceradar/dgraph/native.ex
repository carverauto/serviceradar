defmodule ServiceRadar.Dgraph.Native do
  @moduledoc """
  Rustler NIF bindings for `dgraph_topology`.

  The BEAM-visible seam for Dgraph. Typed write maps cross the ABI as `NifMap`
  structs; the read-only DQL hatch returns JSON. Callers should use
  `ServiceRadar.Dgraph`, which supplies the connection URL and refuses
  mutations before they reach this module.
  """

  use Rustler,
    otp_app: :serviceradar_core,
    crate: "dgraph_nif"

  @type url :: String.t()
  @type write_result :: :ok | {:error, String.t()}
  @type count_result :: {:ok, non_neg_integer()} | {:error, String.t()}
  @type json_result :: {:ok, String.t()} | {:error, String.t()}
  @type edges_result :: {:ok, [map()]} | {:error, String.t()}

  @spec upsert_device(url(), map()) :: write_result()
  def upsert_device(_url, _device), do: :erlang.nif_error(:nif_not_loaded)

  @spec upsert_interface(url(), map()) :: write_result()
  def upsert_interface(_url, _iface), do: :erlang.nif_error(:nif_not_loaded)

  @spec upsert_prefix(url(), map()) :: write_result()
  def upsert_prefix(_url, _prefix), do: :erlang.nif_error(:nif_not_loaded)

  @spec attach_prefix(url(), String.t(), String.t()) :: write_result()
  def attach_prefix(_url, _iface_key, _cidr), do: :erlang.nif_error(:nif_not_loaded)

  @spec upsert_change(url(), map()) :: write_result()
  def upsert_change(_url, _change), do: :erlang.nif_error(:nif_not_loaded)

  @spec upsert_hop(url(), map()) :: write_result()
  def upsert_hop(_url, _hop), do: :erlang.nif_error(:nif_not_loaded)

  @spec upsert_edge(url(), map()) :: write_result()
  def upsert_edge(_url, _edge), do: :erlang.nif_error(:nif_not_loaded)

  @spec upsert_canonical_edge(url(), map()) :: write_result()
  def upsert_canonical_edge(_url, _edge), do: :erlang.nif_error(:nif_not_loaded)

  @spec upsert_mtr_path(url(), map()) :: write_result()
  def upsert_mtr_path(_url, _edge), do: :erlang.nif_error(:nif_not_loaded)

  @spec prune_stale(url(), String.t()) :: count_result()
  def prune_stale(_url, _cutoff), do: :erlang.nif_error(:nif_not_loaded)

  @spec rebuild_canonical(url(), [map()]) :: write_result()
  def rebuild_canonical(_url, _edges), do: :erlang.nif_error(:nif_not_loaded)

  @spec query_canonical_edges(url()) :: edges_result()
  def query_canonical_edges(_url), do: :erlang.nif_error(:nif_not_loaded)

  @spec query_neighbourhood(url(), String.t()) :: edges_result()
  def query_neighbourhood(_url, _device_id), do: :erlang.nif_error(:nif_not_loaded)

  @spec query_dql(url(), String.t()) :: json_result()
  def query_dql(_url, _dql), do: :erlang.nif_error(:nif_not_loaded)
end
