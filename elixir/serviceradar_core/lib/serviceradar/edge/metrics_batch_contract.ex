defmodule ServiceRadar.Edge.MetricsBatchContract do
  @moduledoc """
  The passive agent metrics output contract (`serviceradar.metrics.batch` v1) as this
  installation admits it. Its payload is a `metric.v1.MetricBatch` from a producer core does not
  schedule (sysmon), emitted under a standing output grant, so its records carry no source
  authorization. Metrics from lease-run producers (SNMP, ICMP, MTR, rperf, sweeps) use the
  separate scheduled metrics contract, with the same payload. The lookup and its refusals are
  `ServiceRadar.Edge.OutputContract`'s.

  A record projects one row per metric point, with a 1 KiB write budget per row, and at most
  10000 rows.
  """

  alias ServiceRadar.Edge.OutputContract

  @ref {"serviceradar.metrics.batch", 1}
  @bounds %{max_projected_rows: 10_000, write_bytes_per_row: 1_024}

  @doc "The contract id and version."
  @spec ref() :: {String.t(), pos_integer()}
  def ref, do: @ref

  @doc "The configured metrics batch contract, or why core cannot sign against it."
  @spec current() :: {:ok, OutputContract.t()} | {:error, term()}
  def current, do: OutputContract.current(@ref, @bounds)

  @doc "The metrics batch contract named by a registry document."
  @spec from_document(term()) :: {:ok, OutputContract.t()} | {:error, term()}
  def from_document(raw), do: OutputContract.from_document(raw, @ref, @bounds)
end
