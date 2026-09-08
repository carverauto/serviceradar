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

  @spec sweep(%SweepObservationBatchV1{}) :: [row()]
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

  @spec mtr(%MtrTraceBatchV1{}) :: [row()]
  def mtr(%MtrTraceBatchV1{traces: traces}) do
    traces
    |> Enum.with_index()
    |> Enum.flat_map(fn {trace, i} ->
      [{"mtr_trace", i, -1} | indexed(trace.hops, "mtr_hop", i)]
    end)
  end

  @spec sweep_count(%SweepObservationBatchV1{}) :: non_neg_integer()
  def sweep_count(batch), do: batch |> sweep() |> length()

  @spec mtr_count(%MtrTraceBatchV1{}) :: non_neg_integer()
  def mtr_count(batch), do: batch |> mtr() |> length()

  defp indexed(elements, kind, batch_index) do
    elements |> Enum.with_index() |> Enum.map(fn {_, j} -> {kind, batch_index, j} end)
  end
end
