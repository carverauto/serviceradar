defmodule ServiceRadar.TopologyAtlas.Native do
  @moduledoc false

  use Rustler,
    otp_app: :serviceradar_core,
    crate: "topology_atlas_nif"

  def new_builder(_layout_version, _zmax), do: :erlang.nif_error(:nif_not_loaded)
  def add_positions(_builder, _rows), do: :erlang.nif_error(:nif_not_loaded)
  def add_relations(_builder, _rows), do: :erlang.nif_error(:nif_not_loaded)
  def add_inventory(_builder, _rows), do: :erlang.nif_error(:nif_not_loaded)
  def finish_world(_builder), do: :erlang.nif_error(:nif_not_loaded)
  def read_graph(_url), do: :erlang.nif_error(:nif_not_loaded)
  def reconcile(_builder, _graph), do: :erlang.nif_error(:nif_not_loaded)
  def candidate_info(_candidate), do: :erlang.nif_error(:nif_not_loaded)
  def world_info(_world), do: :erlang.nif_error(:nif_not_loaded)
  def tile(_world, _z, _x, _y, _budget), do: :erlang.nif_error(:nif_not_loaded)
  def search(_world, _id), do: :erlang.nif_error(:nif_not_loaded)
  def positions_page(_candidate, _cursor, _limit), do: :erlang.nif_error(:nif_not_loaded)
  def relations_page(_candidate, _cursor, _limit), do: :erlang.nif_error(:nif_not_loaded)
  def delta_page(_candidate, _operation, _cursor, _limit), do: :erlang.nif_error(:nif_not_loaded)
end
