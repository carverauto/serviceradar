defmodule ServiceRadar.Edge.SweepContract do
  @moduledoc """
  The sweep observation output contract as this installation admits it: the values core signs
  into a sweep lease's production capability. The lookup and its refusals are
  `ServiceRadar.Edge.OutputContract`'s.

  The per-record bounds are the sweep contract's own. A batch projects one reachability row
  per host plus one row per open port and per port error, plus an MTR summary
  (`projection.SweepProjectionRows`, `obsbatch.hostCost`). The ceiling is
  `obsbatch.DefaultMaxSweepRows` (10000) projected rows per batch, with a 2 KiB write budget
  per projected row.
  """

  alias ServiceRadar.Edge.OutputContract

  @ref {"serviceradar.sweep.observation", 1}
  @bounds %{max_projected_rows: 10_000, write_bytes_per_row: 2_048}

  @type t :: OutputContract.t()

  @doc "The configured sweep contract, or why core cannot sign against it."
  @spec current() :: {:ok, t()} | {:error, term()}
  def current, do: OutputContract.current(@ref, @bounds)

  @doc "The sweep contract named by a registry document."
  @spec from_document(term()) :: {:ok, t()} | {:error, term()}
  def from_document(raw), do: OutputContract.from_document(raw, @ref, @bounds)
end
