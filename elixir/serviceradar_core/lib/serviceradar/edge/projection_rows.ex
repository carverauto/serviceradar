defmodule ServiceRadar.Edge.ProjectionRows do
  @moduledoc """
  Enumerates synchronous domain rows for an already validated decoded batch.

  Coordinates are `{kind, batch_index, element_index}`; `-1` means the host or
  trace's own row. Their list order matches the Go projection core. This is a
  projection rule, not admission, authorization, or a database writer.
  """

  alias Serviceradar.Edge.V1.MtrTraceBatchV1
  alias Serviceradar.Edge.V1.SweepObservationBatchV1

  @type row :: {String.t(), non_neg_integer(), integer()}

  @spec sweep(SweepObservationBatchV1.t()) :: [row()]
  def sweep(%SweepObservationBatchV1{hosts: hosts}) do
    hosts
    |> Enum.with_index()
    |> Enum.flat_map(fn {host, i} ->
      [{"reachability", i, -1}] ++
        indexed(host.open_ports, "open_port", i) ++
        indexed(host.port_errors, "port_error", i) ++
        if(is_nil(host.mtr), do: [], else: [{"mtr_summary", i, -1}])
    end)
  end

  @spec mtr(MtrTraceBatchV1.t()) :: [row()]
  def mtr(%MtrTraceBatchV1{traces: traces}) do
    traces
    |> Enum.with_index()
    |> Enum.flat_map(fn {trace, i} ->
      [{"mtr_trace", i, -1} | indexed(trace.hops, "mtr_hop", i)]
    end)
  end

  @spec sweep_count(SweepObservationBatchV1.t()) :: non_neg_integer()
  def sweep_count(batch), do: batch |> sweep() |> length()

  @spec mtr_count(MtrTraceBatchV1.t()) :: non_neg_integer()
  def mtr_count(batch), do: batch |> mtr() |> length()

  @doc """
  Elixir twin of `go/pkg/edge/projection/projection.go`'s `RowKey/2`.

  Derives a stable idempotency key for the row at `ordinal` within a frame
  whose immutable semantic digest is `semantic_digest`: SHA-256 of the
  digest's length (big-endian u64), the digest itself, then `ordinal`
  (big-endian u64). Byte-identical to the Go implementation (cross-checked
  against golden vectors from `projection.RowKey` in
  `projection_rows_test.exs`), so re-projecting a redelivered frame yields the
  same key and a table keyed on it upserts instead of duplicating.
  """
  @spec row_key(binary(), non_neg_integer()) :: binary()
  def row_key(semantic_digest, ordinal)
      when is_binary(semantic_digest) and is_integer(ordinal) and ordinal >= 0 do
    :crypto.hash(:sha256, [
      <<byte_size(semantic_digest)::big-64>>,
      semantic_digest,
      <<ordinal::big-64>>
    ])
  end

  defp indexed(elements, kind, batch_index) do
    elements |> Enum.with_index() |> Enum.map(fn {_, j} -> {kind, batch_index, j} end)
  end
end
